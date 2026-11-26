import daemonBridge from 'libharbor_bridge.so';
import hilog from '@ohos.hilog';
import fileIo from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { HarborIcon, Palette } from '../components/HarborAppearance';
import { ServiceLog } from '../components/ServiceLog';
import { applyTheme, saveTheme, THEME_STORAGE, ThemePreference } from '../components/ThemePreference';
import { brewUnitMissing, cleanupBrewApps, CleanupResult } from '../ipc/BrewUnit';

const DOMAIN = 0x0000;
const TAG = 'Harbor';
const CONFIG_PATH = '/storage/Users/currentUser/.config/harbor/apps.json';

const CONFIG_LABEL = '~/.config/harbor/apps.json';
const WIDE_WINDOW = 970;
const THEME_VALUES: ThemePreference[] = [ThemePreference.System, ThemePreference.Light, ThemePreference.Dark];
const THEME_OPTIONS: SelectOption[] = [{ value: '跟随系统' }, { value: '浅色' }, { value: '深色' }];

interface ServiceFilter {
  id: string;
  label: string;
  icon: string;
}

const FILTERS: ServiceFilter[] = [
  { id: 'all', label: '全部服务', icon: 'list' },
  { id: 'started', label: '运行中', icon: 'activity' },
  { id: 'inactive', label: '未运行', icon: 'pause' },
  { id: 'disabled', label: '已禁用', icon: 'disabled' },
  { id: 'error', label: '配置异常', icon: 'warning' }
];

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
  status: string;             // started | stopped | none | disabled | error | not-found
  pid: number;
  enabled: boolean;
  timerText: string;
  bin: string;
  unit: string;
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
  if (s === 'not-found') return '已卸载';
  if (s === 'error') return '配置异常';
  return '未启动';
}

function statusColor(s: string): ResourceColor {
  if (s === 'started') return Palette.accent;
  if (s === 'error' || s === 'not-found') return Palette.danger;
  if (s === 'stopped' || s === 'none') return Palette.amber;
  return Palette.muted;
}

function matchesService(service: ServiceState, filter: string, query: string): boolean {
  const status = service.status;
  const isIssue = status === 'error' || status === 'not-found';
  return (filter === 'all' || filter === status ||
    (filter === 'error' && isIssue) ||
    (filter === 'inactive' && (status === 'stopped' || status === 'none'))) &&
    service.name.toLowerCase().includes(query.trim().toLowerCase());
}

@Entry
@Component
struct Index {
  @StorageLink(THEME_STORAGE) theme: ThemePreference = ThemePreference.System;
  @State themeSaving: boolean = false;
  @State themeMessage: string = '';
  @State visibleServices: ServiceState[] = [];
  @State selected: ServiceState | undefined = undefined;
  @State filter: string = 'all';
  @State query: string = '';
  @State tab: string = 'overview';
  @State wide: boolean = false;
  @State showDetail: boolean = false;
  @State serviceCount: number = 0;
  @State runningCount: number = 0;
  @State stoppedCount: number = 0;
  @State disabledCount: number = 0;
  @State errorCount: number = 0;
  @State configFailed: boolean = false;
  @State updatedAt: string = '';
  @State pendingService: string = '';
  @State actionNotice: string = '';
  @State cleanupNotice: string = '';
  @State confirmRemove: boolean = false;
  private services: ServiceState[] = [];
  private refreshTimer: number = -1;

  // 读配置 -> 解析每个服务 -> 查 pidfile 得到状态
  refresh(): void {
    const next: ServiceState[] = [];
    let running = 0, stopped = 0, disabled = 0, errors = 0;
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
        const staleBrew: boolean = app.type === 'unit' && app.unit !== undefined &&
          app.enabled !== false && brewUnitMissing(app.unit);
        if (staleBrew) {
          status = 'not-found';  // brew 已卸载，优先于 disabled/进程状态
        } else if (app.enabled === false) {
          status = 'disabled';
        } else {
          pid = daemonBridge.pidFromPidfile(app.pidfile);
          if (pid > 0) status = 'started';
          else if (daemonBridge.pidfileExists(app.pidfile) === 1) status = 'stopped';
          if (bin.length === 0 && status !== 'disabled') status = 'error';
        }
        if (status === 'started') running++;
        else if (status === 'disabled') disabled++;
        else if (status === 'error') errors++;
        else stopped++;
        next.push({
          name: app.name,
          type: app.type === 'unit' ? 'unit' : 'exec',
          status: status,
          pid: pid,
          enabled: app.enabled !== false,
          timerText: formatTimer(app.timer),
          bin: bin,
          unit: app.unit ?? '',
          args: args,
          log: log,
          pidfile: app.pidfile,
          env: env
        });
      }
      this.configFailed = false;
    } catch (err) {
      this.configFailed = true;
      hilog.error(DOMAIN, TAG, 'read config failed: %{public}s', JSON.stringify(err));
    }
    this.services = next;
    this.serviceCount = next.length;
    this.runningCount = running;
    this.stoppedCount = stopped;
    this.disabledCount = disabled;
    this.errorCount = errors;
    this.updateVisibleServices();
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

  private updateVisibleServices(): void {
    const visible = this.services.filter((service: ServiceState) => matchesService(service, this.filter, this.query));
    const selectedId = this.selected?.pidfile;
    // Keep the selected service visible while an action moves it out of the current filter.
    const selected = this.services.find((service: ServiceState) => service.pidfile === selectedId);
    this.visibleServices = visible;
    this.selected = selected ?? visible[0];
    if (!this.selected) this.showDetail = false;
    if (selectedId !== this.selected?.pidfile) {
      this.tab = 'overview';
      this.actionNotice = '';
    }
  }

  private applyFilter(filter: string, query: string): void {
    this.filter = filter;
    this.query = query;
    if (this.selected && !matchesService(this.selected, filter, query)) {
      this.selected = undefined;
      this.tab = 'overview';
      this.actionNotice = '';
    }
    this.updateVisibleServices();
  }

  private selectService(service: ServiceState): void {
    this.selected = this.services.find((current: ServiceState) => current.pidfile === service.pidfile);
    this.tab = 'overview';
    this.actionNotice = '';
    this.showDetail = true;
  }

  private runAction(action: string): void {
    const service = this.selected;
    if (!service || this.pendingService || !service.enabled || !service.bin) return;
    this.pendingService = service.pidfile;
    this.actionNotice = action + '中…';
    if (action !== '启动') this.stopOne(service);
    if (action === '启动') this.startOne(service);
    if (action === '重启') setTimeout(() => { this.startOne(service); }, 400);
    setTimeout(() => {
      this.refresh();
      const current = this.services.find((item: ServiceState) => item.pidfile === service.pidfile);
      const running = current?.status === 'started';
      if (this.selected?.pidfile === service.pidfile) {
        const confirmed = !this.configFailed && current !== undefined &&
          (action === '停止' ? !running : running && (action !== '重启' || current.pid !== service.pid));
        this.actionNotice = confirmed ? action + '完成' : '暂未确认' + action + '结果，请查看状态或日志';
      }
      this.pendingService = '';
    }, action === '重启' ? 1000 : 600);
  }

  // 清理失效的 brew 服务（与 CLI harbor cleanup 语义一致）。
  // prune=false 软禁用（可逆）；prune=true 从 apps.json 移除。
  private runCleanup(prune: boolean, name: string): void {
    this.cleanupNotice = '';
    this.confirmRemove = false;
    const result: CleanupResult = cleanupBrewApps(name, prune);
    if (result.error.length > 0) {
      this.cleanupNotice = '清理失败：' + result.error;
      return;
    }
    if (result.disabled.length === 0 && result.removed.length === 0) {
      this.cleanupNotice = '没有需要清理的服务。';
      return;
    }
    const what = result.removed.length > 0
      ? '已移除 ' + result.removed.join('、')
      : '已禁用 ' + result.disabled.join('、') + '（可逆）';
    this.cleanupNotice = what;
    this.actionNotice = '';
    this.refresh();  // 立即重读配置，列表状态同步
  }

  private async changeTheme(index: number): Promise<void> {
    const next = THEME_VALUES[index];
    if (!next || this.themeSaving || next === this.theme) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.themeMessage = '';
    try {
      applyTheme(context, next);
    } catch (error) {
      this.themeMessage = '无法切换主题，请重试';
      return;
    }
    this.theme = next;
    this.themeSaving = true;
    try {
      await saveTheme(context, next);
    } catch (error) {
      this.themeMessage = '主题已切换，保存失败';
    } finally {
      this.themeSaving = false;
    }
  }

  @Builder
  brand() {
    Row({ space: 10 }) {
      Row() {
        HarborIcon({ name: 'anchor', tint: Palette.rail, iconSize: 26 })
      }
      .width(36).height(36).justifyContent(FlexAlign.Center)
      .borderRadius(10).backgroundColor(Palette.mint)
      Text('Harbor').fontSize(22).fontWeight(FontWeight.Bold).fontColor(Color.White)
    }
  }

  @Builder
  filterButton(item: ServiceFilter, sidebar: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        if (sidebar) {
          HarborIcon({ name: item.icon, tint: this.filter === item.id ? Palette.mint : Palette.railMuted })
        }
        Text(item.label).fontSize(13).fontWeight(this.filter === item.id ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(sidebar ? (this.filter === item.id ? Palette.mint : Palette.railText) :
            (this.filter === item.id ? Palette.accent : Palette.muted))
      }
      .width(sidebar ? '100%' : undefined)
    }
    .id('filter-' + item.id)
    .height(sidebar ? 42 : 34).borderRadius(8)
    .padding({ left: 11, right: 11 })
    .backgroundColor(this.filter === item.id ? (sidebar ? Palette.railSelected : Palette.selected) : Color.Transparent)
    .onClick(() => { this.applyFilter(item.id, this.query); })
  }

  @Builder
  sidebar() {
    Column({ space: 5 }) {
      this.brand()
      Divider().color(Palette.railSelected).margin({ top: 20, bottom: 16 })
      ForEach(FILTERS, (item: ServiceFilter) => {
        this.filterButton(item, true)
      }, (item: ServiceFilter) => item.id)
      Blank()
      Row({ space: 8 }) {
        HarborIcon({ name: 'device', tint: Palette.railMuted })
        Text('本机服务').fontSize(12).fontColor(Palette.railText)
      }
      .padding(10)
    }
    .width(176).height('100%').padding({ left: 14, right: 14, top: 24, bottom: 14 })
    .alignItems(HorizontalAlign.Start).backgroundColor(Palette.rail)
  }

  @Builder
  summary() {
    Row() {
      ServiceMetric({ label: '服务总数', value: this.serviceCount, tint: Palette.ink, wide: this.wide })
      Divider().vertical(true).height(34).color(Palette.line)
      ServiceMetric({ label: '运行中', value: this.runningCount, tint: Palette.accent, wide: this.wide })
      Divider().vertical(true).height(34).color(Palette.line)
      ServiceMetric({ label: '未运行', value: this.stoppedCount, tint: Palette.amber, wide: this.wide })
      Divider().vertical(true).height(34).color(Palette.line)
      ServiceMetric({ label: '已禁用', value: this.disabledCount, tint: Palette.muted, wide: this.wide })
      if (this.errorCount > 0) {
        Divider().vertical(true).height(34).color(Palette.line)
        ServiceMetric({ label: '异常', value: this.errorCount, tint: Palette.danger, wide: this.wide })
      }
    }
    .width('100%').backgroundColor(Palette.surface).borderRadius(12)
    .border({ color: Palette.line, width: 1 })
  }

  @Builder
  serviceRow(service: ServiceState) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        Row() {
          HarborIcon({ name: service.type === 'unit' ? 'layers' : 'terminal', tint: Palette.accent })
        }
        .width(34).height(34).justifyContent(FlexAlign.Center)
        .borderRadius(8).backgroundColor(Palette.selected)
        Column({ space: 3 }) {
          Text(service.name).fontSize(14).fontWeight(FontWeight.Bold).fontColor(Palette.ink)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(service.type === 'unit' ? 'Systemd 单元' : '可执行程序')
            .fontSize(11).fontColor(Palette.muted).maxLines(1)
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
        Row() { StatusBadge({ status: service.status }) }.width(82)
        if (this.wide) {
          Text(service.pid > 0 ? service.pid.toString() : '—')
            .fontSize(12).fontFamily('monospace').fontColor(Palette.muted).width(55).maxLines(1)
        }
        HarborIcon({ name: 'chevron', tint: Palette.muted })
      }
      .width('100%')
    }
    .id('service-' + service.name)
    .width('100%').height(58).borderRadius(0).padding({ left: 12, right: 8 })
    .backgroundColor(this.wide && this.selected?.pidfile === service.pidfile ? Palette.selected : Palette.surface)
    .onClick(() => { this.selectService(service); })
  }

  @Builder
  emptyState(icon: string, title: string, detail: string) {
    Column({ space: 10 }) {
      Row() { HarborIcon({ name: icon, tint: Palette.accent }) }
        .width(42).height(42).justifyContent(FlexAlign.Center).borderRadius(11).backgroundColor(Palette.selected)
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(Palette.ink).textAlign(TextAlign.Center)
      Text(detail).fontSize(12).fontColor(Palette.muted).textAlign(TextAlign.Center).wordBreak(WordBreak.BREAK_ALL)
    }
    .width('100%').layoutWeight(1).padding(18).justifyContent(FlexAlign.Center)
  }

  @Builder
  serviceTable() {
    Column() {
      Row({ space: 8 }) {
        HarborIcon({ name: 'search', tint: Palette.muted })
        TextInput({ placeholder: '按名称搜索服务', text: this.query })
          .id('search-services').layoutWeight(1).height(36).fontSize(13).fontColor(Palette.ink)
          .placeholderColor(Palette.muted).backgroundColor(Color.Transparent).padding(0)
          .cancelButton({ style: CancelButtonStyle.INPUT })
          .onChange((value: string) => { this.applyFilter(this.filter, value); })
        if (this.wide) {
          Text(this.visibleServices.length + ' 项').fontSize(12).fontColor(Palette.muted)
        }
      }
      .width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
      if (this.visibleServices.some((s: ServiceState) => s.status === 'not-found')) {
        Row({ space: 8 }) {
          Text(this.visibleServices.filter((s: ServiceState) => s.status === 'not-found').length +
            ' 个 brew 服务已卸载').fontSize(12).fontColor(Palette.danger).layoutWeight(1)
          Button('清理全部（禁用）', { type: ButtonType.Normal })
            .id('cleanup-all').height(30).fontSize(12).fontColor(Palette.onAccent)
            .backgroundColor(Palette.accent)
            .onClick(() => { this.runCleanup(false, ''); })
        }
        .width('100%').padding({ left: 12, right: 12, top: 4, bottom: 8 })
      }
      if (this.cleanupNotice.length > 0) {
        Text(this.cleanupNotice).fontSize(12).fontColor(Palette.muted)
          .width('100%').padding({ left: 12, right: 12, bottom: 6 })
      }
      Divider().color(Palette.line)
      if (this.visibleServices.length > 0) {
        Row({ space: 10 }) {
          Text('服务名称').layoutWeight(1).fontSize(12).fontColor(Palette.muted)
          Text('状态').width(82).fontSize(12).fontColor(Palette.muted)
          if (this.wide) {
            Text('PID').width(55).fontSize(12).fontColor(Palette.muted)
          }
          Blank().width(20)
        }
        .width('100%').height(32).padding({ left: 12, right: 8 }).backgroundColor(Palette.soft)
        List() {
          ForEach(this.visibleServices, (service: ServiceState) => {
            ListItem() { this.serviceRow(service) }
          }, (service: ServiceState) => JSON.stringify([service.pidfile, service.name, service.type, service.status,
            service.pid]))
        }
        .width('100%').layoutWeight(1).divider({ strokeWidth: 1, color: Palette.line })
        .edgeEffect(EdgeEffect.None)
      } else if (this.configFailed) {
        this.emptyState('warning', '无法读取服务配置', CONFIG_LABEL)
      } else if (this.serviceCount === 0) {
        this.emptyState('layers', '尚未配置服务', '在 ' + CONFIG_LABEL + ' 中添加服务')
      } else {
        this.emptyState('search', '没有匹配的服务', '试试其他名称或状态筛选')
      }
    }
    .width('100%').layoutWeight(1).clip(true).borderRadius(12).backgroundColor(Palette.surface)
    .border({ color: Palette.line, width: 1 })
  }

  @Builder
  workspace() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text('服务管理').fontSize(27).fontWeight(FontWeight.Bold).fontColor(Palette.ink)
          if (this.updatedAt) {
            Text('更新于 ' + this.updatedAt).fontSize(12).fontColor(Palette.muted)
          }
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
        Select(THEME_OPTIONS)
          .id('appearance-select').accessibilityDescription('界面主题')
          .selected(THEME_VALUES.indexOf(this.theme)).value(THEME_OPTIONS[THEME_VALUES.indexOf(this.theme)].value)
          .font({ size: 13, weight: FontWeight.Medium }).fontColor(Palette.ink)
          .height(36).backgroundColor(Palette.surface).borderRadius(8)
          .border({ color: Palette.line, width: 1 }).enabled(!this.themeSaving)
          .onSelect((index: number) => { void this.changeTheme(index); })
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            HarborIcon({ name: 'refresh', tint: Palette.ink, iconSize: 22 })
            Text('刷新').fontSize(13).fontWeight(FontWeight.Medium).fontColor(Palette.ink)
          }
        }
        .id('refresh-services').height(36).padding({ left: 10, right: 12 }).borderRadius(8)
        .backgroundColor(Palette.surface).border({ color: Palette.line, width: 1 })
        .onClick(() => { this.refresh(); })
      }
      .width('100%')
      if (this.themeMessage) {
        Text(this.themeMessage).width('100%').fontSize(12).fontColor(Palette.danger)
      }
      if (!this.configFailed) {
        this.summary()
      }
      if (!this.wide) {
        Scroll() {
          Row({ space: 5 }) {
            ForEach(FILTERS, (item: ServiceFilter) => { this.filterButton(item, false) },
              (item: ServiceFilter) => item.id)
          }
        }
        .width('100%').height(36).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        .align(Alignment.Start)
      }
      this.serviceTable()
    }
    .layoutWeight(1).height('100%').padding(this.wide ? 22 : 14).backgroundColor(Palette.canvas)
  }

  @Builder
  actionButton(label: string, primary: boolean) {
    Button(label, { type: ButtonType.Normal })
      .id('service-action-' + label).height(36).borderRadius(8).layoutWeight(1)
      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(primary ? Palette.onAccent : Palette.danger)
      .backgroundColor(primary ? Palette.accent : Palette.dangerSoft)
      .enabled(this.pendingService.length === 0).onClick(() => { this.runAction(label); })
  }

  @Builder
  detailTab(id: string, label: string) {
    Button(label, { type: ButtonType.Normal })
      .id('detail-' + id).height(32).borderRadius(6).layoutWeight(1).fontSize(13)
      .fontWeight(this.tab === id ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.tab === id ? Palette.accent : Palette.muted)
      .backgroundColor(this.tab === id ? Palette.surface : Color.Transparent)
      .onClick(() => { this.tab = id; })
  }

  @Builder
  overview() {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          Column({ space: 5 }) {
            Text('进程 PID').fontSize(12).fontColor(Palette.muted)
            Text(this.selected && this.selected.pid > 0 ? this.selected.pid.toString() : '—')
              .fontSize(17).fontFamily('monospace').fontWeight(FontWeight.Medium).fontColor(Palette.ink)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Column({ space: 5 }) {
            Text('定时计划').fontSize(12).fontColor(Palette.muted)
            Text(this.selected?.timerText || '未设置').fontSize(13).fontColor(Palette.ink)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }
        .width('100%').padding(12).borderRadius(8).backgroundColor(Palette.soft)
        DetailField({ label: '可执行文件', value: this.selected?.bin || '缺少启动命令' })
        if (this.selected?.args.length) {
          DetailField({ label: '启动参数', value: JSON.stringify(this.selected.args) })
        }
        if (this.selected?.unit) {
          DetailField({ label: '单元文件', value: this.selected.unit })
        }
        DetailField({ label: 'PID 文件', value: this.selected?.pidfile || '—' })
      }
      .width('100%').alignItems(HorizontalAlign.Start).padding({ left: 18, right: 18, top: 16, bottom: 18 })
    }
    .width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
  }

  @Builder
  details() {
    Column() {
      if (this.selected) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            if (!this.wide) {
              Button('返回列表', { type: ButtonType.Normal })
                .id('back-to-services').height(32).borderRadius(6).padding({ left: 8, right: 8 })
                .fontSize(12).fontColor(Palette.accent).backgroundColor(Palette.selected)
                .onClick(() => { this.showDetail = false; })
            } else {
              Text('服务详情').fontSize(12).fontWeight(FontWeight.Medium).fontColor(Palette.muted)
            }
          }.width('100%')
          Text(this.selected.name).fontSize(23).fontWeight(FontWeight.Bold).fontColor(Palette.ink)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 10 }) {
            StatusBadge({ status: this.selected.status })
            Text(this.selected.type === 'unit' ? 'Systemd 单元' : '可执行程序').fontSize(12).fontColor(Palette.muted)
          }
          if (this.selected.enabled && this.selected.bin) {
            Row({ space: 8 }) {
              if (this.selected.status === 'started') {
                this.actionButton('重启', true)
                this.actionButton('停止', false)
              } else {
                this.actionButton('启动', true)
              }
            }.width('100%')
          }
          if (this.selected.status === 'not-found') {
            Column({ space: 8 }) {
              Text('brew formula 已卸载（unit 文件不存在），可在界面直接清理。')
                .fontSize(12).fontColor(Palette.danger).width('100%')
              if (!this.confirmRemove) {
                Row({ space: 8 }) {
                  Button('清理（禁用，可逆）', { type: ButtonType.Normal })
                    .id('cleanup-soft-' + this.selected.name).height(34).layoutWeight(1)
                    .fontSize(12).fontColor(Palette.onAccent).backgroundColor(Palette.accent)
                    .onClick(() => { this.runCleanup(false, this.selected!.name); })
                  Button('移除', { type: ButtonType.Normal })
                    .id('cleanup-remove-' + this.selected.name).height(34).layoutWeight(1)
                    .fontSize(12).fontColor(Palette.danger).backgroundColor(Palette.dangerSoft)
                    .onClick(() => { this.confirmRemove = true; })
                }.width('100%')
              } else {
                Row({ space: 8 }) {
                  Text('确认从配置中移除？').fontSize(12).fontColor(Palette.ink).layoutWeight(1)
                  Button('取消', { type: ButtonType.Normal }).height(34)
                    .fontSize(12).fontColor(Palette.muted).backgroundColor(Palette.soft)
                    .onClick(() => { this.confirmRemove = false; })
                  Button('确认移除', { type: ButtonType.Normal }).height(34)
                    .fontSize(12).fontColor(Palette.onAccent).backgroundColor(Palette.danger)
                    .onClick(() => { this.runCleanup(true, this.selected!.name); })
                }.width('100%')
              }
              if (this.cleanupNotice) {
                Text(this.cleanupNotice).fontSize(12).fontColor(Palette.muted).width('100%')
              }
            }
            .width('100%').padding(10).borderRadius(8).backgroundColor(Palette.dangerSoft)
          }
          if (this.actionNotice) {
            Text(this.actionNotice).fontSize(12).fontColor(Palette.muted)
          }
          if (this.selected.status !== 'not-found' && this.cleanupNotice) {
            Text(this.cleanupNotice).fontSize(12).fontColor(Palette.accent).width('100%')
          }
          Row({ space: 3 }) {
            this.detailTab('overview', '概览')
            this.detailTab('log', '日志')
          }
          .width('100%').padding(3).borderRadius(8).backgroundColor(Palette.soft)
        }
        .width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 18, right: 18, top: 20, bottom: 14 })
        Divider().color(Palette.line)
        if (this.tab === 'overview') {
          this.overview()
        } else {
          ServiceLog({ path: this.selected.log })
        }
      } else {
        this.emptyState('layers', '服务详情', '选择一项服务以查看运行信息与日志')
      }
    }
    .height('100%').width(this.wide ? 300 : '100%')
    .backgroundColor(Palette.surface).border({ width: { left: this.wide ? 1 : 0 }, color: Palette.line })
  }

  build() {
    Row() {
      if (this.wide) {
        this.sidebar()
      }
      if (this.wide || !this.showDetail) {
        this.workspace()
      }
      if (this.wide || this.showDetail) {
        this.details()
      }
    }
    .width('100%').height('100%').backgroundColor(Palette.canvas)
    .onAreaChange((_previous: Area, area: Area) => {
      this.wide = Number(area.width) >= WIDE_WINDOW;
    })
  }
}

@Component
struct ServiceMetric {
  @Prop label: string;
  @Prop value: number;
  @Prop tint: ResourceColor;
  @Prop wide: boolean;

  build() {
    Column({ space: 4 }) {
      Text(this.value.toString()).fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.tint)
      Text(this.label).fontSize(11).fontColor(Palette.muted).maxLines(1)
    }
    .layoutWeight(1).alignItems(HorizontalAlign.Start)
    .padding({ left: this.wide ? 18 : 10, right: 6, top: 12, bottom: 12 })
  }
}

@Component
struct StatusBadge {
  @Prop status: string;

  build() {
    Row({ space: 5 }) {
      Circle({ width: 7, height: 7 }).fill(statusColor(this.status))
      Text(statusText(this.status)).fontSize(12).fontWeight(FontWeight.Medium).fontColor(statusColor(this.status))
    }
  }
}

@Component
struct DetailField {
  @Prop label: string;
  @Prop value: string;

  build() {
    Column({ space: 5 }) {
      Text(this.label).fontSize(12).fontColor(Palette.muted)
      Text(this.value).fontSize(13).fontColor(Palette.ink).fontFamily('monospace')
        .copyOption(CopyOptions.LocalDevice).width('100%').wordBreak(WordBreak.BREAK_ALL)
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }
}
