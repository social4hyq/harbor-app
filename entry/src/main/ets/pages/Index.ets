import daemonBridge from 'libharbor_bridge.so';
import hilog from '@ohos.hilog';
import fileIo from '@ohos.file.fs';

const DOMAIN = 0x0000;
const TAG = 'Harbor';
const CONFIG_PATH = '/storage/Users/currentUser/.config/harbor/apps.json';

// ---- 配色 ----
const C_BLUE: string = '#1565C0';
const C_BLUE_LIGHT: string = '#1E88E5';
const C_GREEN: string = '#2E7D32';
const C_GREEN_BG: string = '#E8F5E9';
const C_GRAY: string = '#90A4AE';
const C_GRAY_BG: string = '#ECEFF1';
const C_RED: string = '#C62828';
const C_RED_BG: string = '#FFEBEE';
const C_INK: string = '#263238';
const C_SUB: string = '#78909C';
const C_CARD: string = '#FFFFFF';
const C_PAGE_BG: string = '#F4F7FB';

// ---- 数据模型 ----
interface TimerSpec {
  type?: string;
  onCalendar?: string;
  onUnitActiveSec?: number;
}
interface AppEntry {
  name: string;
  enabled?: boolean;
  type?: string;              // 'unit' | 'exec'
  unit?: string;
  bin?: string;
  args?: string[];
  log?: string;
  pidfile: string;
  env?: Record<string, string>;
  timer?: TimerSpec;
}
interface AppsConfig {
  apps: AppEntry[];
  autoHideOnLaunch?: boolean;
}
interface SvcResult {
  bin: string;
  args: string[];
  env: Record<string, string>;
  log: string;
}
interface ServiceState {
  name: string;
  type: string;
  status: string;             // started | stopped | none | disabled | error
  pid: number;
  enabled: boolean;
  timerText: string;
  bin: string;
  args: string[];
  log: string;
  pidfile: string;
  env: Record<string, string>;
}

// systemd ExecStart 引号分词
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

function parseUnit(path: string): SvcResult {
  const text = fileIo.readTextSync(path);
  let bin = '', log = '';
  let args: string[] = [];
  const env: Record<string, string> = {} as Record<string, string>;
  let inService = false;
  for (const raw of text.split('\n')) {
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

// 把定时器翻译成人话
function formatTimer(t: TimerSpec | undefined): string {
  if (!t) return '';
  if (t.type === 'calendar' && t.onCalendar) {
    const parts = t.onCalendar.trim().split(/\s+/);
    const time = parts[parts.length - 1];
    const day = parts.length === 3 ? parts[0] + ' ' : '每天 ';
    return day + time;
  }
  if (t.type === 'interval' && t.onUnitActiveSec && t.onUnitActiveSec > 0) {
    const s = t.onUnitActiveSec;
    if (s % 3600 === 0) return '每 ' + (s / 3600) + ' 小时';
    if (s % 60 === 0) return '每 ' + (s / 60) + ' 分钟';
    return '每 ' + s + ' 秒';
  }
  return '';
}

function statusText(s: string): string {
  if (s === 'started') return '运行中';
  if (s === 'stopped') return '已停止';
  if (s === 'disabled') return '已禁用';
  if (s === 'error') return '异常';
  return '未启动';
}

function statusColor(s: string): string {
  if (s === 'started') return C_GREEN;
  if (s === 'disabled' || s === 'none') return C_GRAY;
  if (s === 'error') return C_RED;
  return C_SUB;
}

function statusBg(s: string): string {
  if (s === 'started') return C_GREEN_BG;
  if (s === 'error') return C_RED_BG;
  return C_GRAY_BG;
}

@Entry
@Component
struct Index {
  @State services: ServiceState[] = [];
  @State runningCount: number = 0;
  @State stoppedCount: number = 0;
  @State disabledCount: number = 0;
  @State headerInfo: string = '正在读取配置…';
  @State updatedAt: string = '';
  private refreshTimer: number = -1;

  // 读配置 -> 解析每个服务 -> 查 pidfile 得到状态
  refresh(): void {
    const next: ServiceState[] = [];
    let running = 0, stopped = 0, disabled = 0;
    try {
      const text = fileIo.readTextSync(CONFIG_PATH);
      const cfg = JSON.parse(text) as AppsConfig;
      for (const app of cfg.apps) {
        let bin = app.bin ?? '';
        let args = app.args ?? [];
        let log = app.log ?? '';
        const env: Record<string, string> = app.env ?? ({} as Record<string, string>);
        if (app.type === 'unit' && app.unit) {
          try {
            const u = parseUnit(app.unit);
            bin = u.bin; args = u.args; log = u.log;
            for (const k of Object.keys(u.env)) env[k] = u.env[k];
          } catch (e) {
            bin = '';
          }
        }
        let status: string = 'none';
        let pid: number = 0;
        if (app.enabled === false) {
          status = 'disabled';
        } else {
          pid = daemonBridge.pidFromPidfile(app.pidfile);
          if (pid > 0) status = 'started';
          else if (daemonBridge.pidfileExists(app.pidfile) === 1) status = 'stopped';
          if (bin.length === 0 && status !== 'disabled') status = 'error';
        }
        if (status === 'started') running++;
        else if (status === 'disabled') disabled++;
        else stopped++;
        next.push({
          name: app.name,
          type: app.type === 'unit' ? 'unit' : 'exec',
          status: status,
          pid: pid,
          enabled: app.enabled !== false,
          timerText: formatTimer(app.timer),
          bin: bin,
          args: args,
          log: log,
          pidfile: app.pidfile,
          env: env
        });
      }
      this.headerInfo = '配置文件已加载';
    } catch (err) {
      this.headerInfo = '读取配置失败: ' + JSON.stringify(err);
      hilog.error(DOMAIN, TAG, 'read config failed: %{public}s', JSON.stringify(err));
    }
    this.services = next;
    this.runningCount = running;
    this.stoppedCount = stopped;
    this.disabledCount = disabled;
    const now = new Date();
    this.updatedAt = ('0' + now.getHours()).slice(-2) + ':' +
                      ('0' + now.getMinutes()).slice(-2) + ':' +
                      ('0' + now.getSeconds()).slice(-2);
  }

  private startOne(s: ServiceState): void {
    if (s.bin.length === 0 || !s.enabled) return;
    try {
      const r: number = daemonBridge.spawn(
        s.bin, JSON.stringify(s.args) as string, s.log, s.pidfile, JSON.stringify(s.env) as string);
      hilog.info(DOMAIN, TAG, '%{public}s spawn=%{public}d', s.name, r);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '%{public}s spawn failed: %{public}s', s.name, JSON.stringify(e));
    }
  }

  private stopOne(s: ServiceState): void {
    const pid: number = daemonBridge.pidFromPidfile(s.pidfile);
    if (pid <= 0) return;
    try {
      let r: number = daemonBridge.killAndWait(pid, 15, 2000);
      if (r !== 0) daemonBridge.killAndWait(pid, 9, 1000);
      hilog.info(DOMAIN, TAG, '%{public}s stop pid=%{public}d', s.name, pid);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '%{public}s stop failed: %{public}s', s.name, JSON.stringify(e));
    }
  }

  startAll(): void {
    for (const s of this.services) {
      if (s.enabled && s.status !== 'started') this.startOne(s);
    }
    setTimeout(() => { this.refresh(); }, 600);
  }

  aboutToAppear(): void {
    this.refresh();
    // 首次启动自动拉起所有启用服务（Harbor 的核心职责）
    setTimeout(() => { this.startAll(); }, 1500);
    // 每 5 秒刷新，看门狗/定时器拉起的服务实时反映
    this.refreshTimer = setInterval(() => { this.refresh(); }, 5000);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) clearInterval(this.refreshTimer);
  }

  build() {
    Stack() {
      Column() {
        // 顶部品牌横幅
        Column({ space: 0 }) {
          Row({ space: 12 }) {
            Stack() {
              Circle({ width: 48, height: 48 }).fill('#33FFFFFF')
              Image($r('app.media.foreground'))
                .width(30).height(30).objectFit(ImageFit.Contain)
            }
            .width(48).height(48)
            Column({ space: 2 }) {
              Text('Harbor')
                .fontSize(24).fontColor(Color.White).fontWeight(FontWeight.Bold)
              Text('常驻服务管理器')
                .fontSize(12).fontColor('#C8E6FF')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Column({ space: 2 }) {
              Text(this.runningCount + '/' + this.services.length)
                .fontSize(20).fontColor(Color.White).fontWeight(FontWeight.Bold)
              Text('运行中')
                .fontSize(10).fontColor('#C8E6FF')
            }
            .alignItems(HorizontalAlign.Center)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 16, bottom: 16 })
        }
        .width('100%')
        .linearGradient({ angle: 135, colors: [[C_BLUE_LIGHT, 0], [C_BLUE, 1]] })
        .borderRadius({ bottomLeft: 24, bottomRight: 24 })
        .shadow({ radius: 12, color: '#1A1565C0', offsetY: 4 })

        // 内容区
        Column({ space: 12 }) {
          // 统计行（内联，保证 @State 变化实时刷新）
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(this.runningCount.toString()).fontSize(26).fontColor(C_GREEN).fontWeight(FontWeight.Bold)
              Text('运行中').fontSize(11).fontColor(C_SUB)
            }
            .layoutWeight(1).padding({ top: 10, bottom: 10 })
            .backgroundColor(C_CARD).borderRadius(14)
            .shadow({ radius: 6, color: '#12263238', offsetY: 1 })

            Column({ space: 2 }) {
              Text(this.stoppedCount.toString()).fontSize(26).fontColor(C_BLUE).fontWeight(FontWeight.Bold)
              Text('已停止').fontSize(11).fontColor(C_SUB)
            }
            .layoutWeight(1).padding({ top: 10, bottom: 10 })
            .backgroundColor(C_CARD).borderRadius(14)
            .shadow({ radius: 6, color: '#12263238', offsetY: 1 })

            Column({ space: 2 }) {
              Text(this.disabledCount.toString()).fontSize(26).fontColor(C_GRAY).fontWeight(FontWeight.Bold)
              Text('已禁用').fontSize(11).fontColor(C_SUB)
            }
            .layoutWeight(1).padding({ top: 10, bottom: 10 })
            .backgroundColor(C_CARD).borderRadius(14)
            .shadow({ radius: 6, color: '#12263238', offsetY: 1 })
          }
          .width('100%')

          // 分区标题
          Row() {
            Text('服务列表')
              .fontSize(14).fontColor(C_INK).fontWeight(FontWeight.Bold)
            Blank()
            Text('更新于 ' + this.updatedAt)
              .fontSize(11).fontColor(C_SUB)
          }
          .width('100%')
          .margin({ top: 4 })

          // 服务卡片列表
          if (this.services.length === 0) {
            Column({ space: 8 }) {
              Text('📭').fontSize(36)
              Text('暂无服务')
                .fontSize(15).fontColor(C_SUB)
              Text('在 ~/.config/harbor/apps.json 中添加服务配置')
                .fontSize(11).fontColor(C_SUB)
            }
            .width('100%').padding(30)
            .backgroundColor(C_CARD).borderRadius(16)
          } else {
            List({ space: 10 }) {
              ForEach(this.services, (s: ServiceState) => {
                ListItem() {
                  Column() {
                    Row({ space: 12 }) {
                      // 蓝色圆形锚图标
                      Stack() {
                        Circle({ width: 42, height: 42 }).fill(C_BLUE)
                        Image($r('app.media.foreground'))
                          .width(24).height(24).objectFit(ImageFit.Contain)
                      }
                      .width(42).height(42)

                      Column({ space: 3 }) {
                        Text(s.name)
                          .fontSize(16).fontColor(C_INK).fontWeight(FontWeight.Bold)
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Row({ space: 6 }) {
                          Text(s.type.toUpperCase())
                            .fontSize(10).fontColor(C_SUB)
                            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                            .borderRadius(4).backgroundColor(C_GRAY_BG)
                          if (s.timerText.length > 0) {
                            Text('⏱ ' + s.timerText)
                              .fontSize(10).fontColor(C_BLUE)
                              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                              .borderRadius(4).backgroundColor('#E3F2FD')
                          }
                        }
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      // 状态徽章（内联）
                      Row({ space: 6 }) {
                        Circle({ width: 8, height: 8 }).fill(statusColor(s.status))
                        Text(statusText(s.status))
                          .fontSize(12).fontColor(statusColor(s.status)).fontWeight(FontWeight.Medium)
                      }
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .borderRadius(20)
                      .backgroundColor(statusBg(s.status))
                    }
                    .width('100%')

                    Row({ space: 10 }) {
                      Text(s.status === 'started' ? ('PID ' + s.pid) : (s.bin.length > 0 ? s.bin.split('/').slice(-1)[0] : '无 ExecStart'))
                        .fontSize(11).fontColor(C_SUB)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)

                      if (s.status === 'started') {
                        Button('重启')
                          .fontSize(12).fontColor(C_BLUE).backgroundColor('#E3F2FD')
                          .height(30).padding({ left: 14, right: 14 })
                          .onClick(() => { this.stopOne(s); setTimeout(() => { this.startOne(s); this.refresh(); }, 400); })
                        Button('停止')
                          .fontSize(12).fontColor(C_RED).backgroundColor(C_RED_BG)
                          .height(30).padding({ left: 14, right: 14 })
                          .onClick(() => { this.stopOne(s); setTimeout(() => { this.refresh(); }, 400); })
                      } else if (s.enabled) {
                        Button('启动')
                          .fontSize(12).fontColor(Color.White).backgroundColor(C_BLUE)
                          .height(30).padding({ left: 16, right: 16 })
                          .onClick(() => { this.startOne(s); setTimeout(() => { this.refresh(); }, 600); })
                      }
                    }
                    .width('100%')
                    .margin({ top: 12 })
                  }
                  .padding(14)
                  .width('100%')
                  .borderRadius(16)
                  .backgroundColor(C_CARD)
                  .shadow({ radius: 8, color: '#1A263238', offsetX: 0, offsetY: 2 })
                  .border({ width: { left: 3 }, color: statusColor(s.status) })
                }
              }, (s: ServiceState) => s.name + '_' + s.status + '_' + s.pid)
            }
            .width('100%')
            .layoutWeight(1)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(C_PAGE_BG)
    }
    .width('100%')
    .height('100%')
  }
}
