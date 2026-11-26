import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import backgroundTaskManager from '@ohos.backgroundTaskManager';
import wantAgent from '@ohos.wantAgent';
import { BusinessError } from '@ohos.base';
import image from '@ohos.multimedia.image';
import emitter from '@ohos.events.emitter';
import { statusBarManager } from '@kit.StatusBarExtensionKit';
import { IpcServer } from '../ipc/IpcServer';
import { Scheduler } from '../ipc/Scheduler';
import fileIo from '@ohos.file.fs';
import daemonBridge from 'libharbor_bridge.so';
import { applyTheme, readTheme, THEME_STORAGE, ThemePreference } from '../components/ThemePreference';

const DOMAIN = 0x0000;
const TAG = 'Harbor';
const CONFIG_PATH = '/storage/Users/currentUser/.config/harbor/apps.json';

interface HarborConfig { autoHideOnLaunch?: boolean; }
interface AppNameEntry { name: string; }
interface ConfigForCleanup { apps?: AppNameEntry[]; }

function readAutoHide(): boolean {
  try {
    const cfg = JSON.parse(fileIo.readTextSync(CONFIG_PATH)) as HarborConfig;
    return cfg.autoHideOnLaunch === true;
  } catch (e) {
    return false;
  }
}

// 启动时清理已移除服务的残留 pidfile（对齐 brew services cleanup）
function cleanupStalePids(): void {
  try {
    const cfg = JSON.parse(fileIo.readTextSync(CONFIG_PATH)) as ConfigForCleanup;
    const names: string[] = [];
    if (cfg.apps) {
      for (const a of cfg.apps) names.push(a.name);
    }
    const removed: number = daemonBridge.cleanupPidfiles(
      '/data/storage/el2/base/cache/harbor', JSON.stringify(names) as string);
    hilog.info(DOMAIN, TAG, 'cleanupStalePids: removed %{public}d', removed);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'cleanupStalePids failed: %{public}s', JSON.stringify(e));
  }
}

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;
  private trayIcon: image.PixelMap | undefined = undefined;
  private ipc: IpcServer = new IpcServer();
  private scheduler: Scheduler = new Scheduler(this.ipc);

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    try {
      AppStorage.setOrCreate(THEME_STORAGE, readTheme(this.context));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Could not read appearance preference');
    }
    cleanupStalePids();  // 清理已移除服务的残留 pidfile
    this.ipc.start();  // IPC server
    this.scheduler.start();  // 定时调度器（cron/interval）
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
    this.stopKeepAlive();
    try { statusBarManager.removeFromStatusBar(this.context); } catch (e) {}
  }

  // 注册状态栏托盘图标（hideAbility 的前提）
  private setupTray(): void {
    try {
      // 深色壁纸用白线条、浅色壁纸用黑线条（各自 48x48）
      const mkIcon = (res: number): image.PixelMap => {
        const b = this.context.resourceManager.getMediaContentSync(res);
        const src = image.createImageSource(b.buffer as ArrayBuffer);
        try {
          return src.createPixelMapSync({ desiredSize: { width: 48, height: 48 } });
        } finally {
          src.release();
        }
      };
      const iconWhite = mkIcon($r('app.media.tray_white').id);
      const iconBlack = mkIcon($r('app.media.tray_black').id);
      const item: statusBarManager.StatusBarItem = {
        icons: { white: iconWhite, black: iconBlack },
        quickOperation: { title: 'Harbor', height: 80, abilityName: '' },
        statusBarGroupMenu: [[
          { title: '显示窗口', menuCode: 'show', menuAction: { abilityName: '', notifyOnly: true } },
          { title: '退出', menuCode: 'quit', menuAction: { abilityName: '', notifyOnly: true } }
        ]],
        hoverTips: 'Harbor Services'
      };
      statusBarManager.on('statusBarIconClick', (event: emitter.EventData) => {
        if (event.data && event.data['iconClickType'] === 'leftClick') {
          this.context.showAbility().catch((error: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'showAbility failed: %{public}s', JSON.stringify(error));
          });
        }
      });
      statusBarManager.on('rightMenuClick', (event: emitter.EventData) => {
        const code = event.data?.['menuCode'] as string;
        if (code === 'show') {
          this.context.showAbility().catch((error: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'showAbility failed: %{public}s', JSON.stringify(error));
          });
        } else if (code === 'quit') {
          this.stopKeepAlive();
          this.context.terminateSelf().catch((error: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}s', JSON.stringify(error));
          });
        }
      });
      statusBarManager.addToStatusBar(this.context, item);
      hilog.info(DOMAIN, TAG, 'setupTray OK');
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'setupTray failed: %{public}s', JSON.stringify(error));
    }
  }

  async startKeepAlive(): Promise<void> {
    try {
      const wants: Want[] = [{
        bundleName: 'com.social4hyq.harbor',
        abilityName: 'EntryAbility',
        parameters: { fromNotification: true }
      }];
      const agent = await wantAgent.getWantAgent({
        wants: wants,
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1001,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        this.context, backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
      hilog.info(DOMAIN, TAG, 'startBackgroundRunning OK');
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning ERR: %{public}s', JSON.stringify(error));
    }
  }

  stopKeepAlive(): void {
    try {
      backgroundTaskManager.stopBackgroundRunning(this.context, (error: BusinessError) => {
        if (error) hilog.error(DOMAIN, TAG, 'stopBackgroundRunning ERR: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'stopBackgroundRunning throw: %{public}s', JSON.stringify(error));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
      try {
        applyTheme(this.context, AppStorage.get<ThemePreference>(THEME_STORAGE) ?? ThemePreference.System);
      } catch (error) {
        AppStorage.setOrCreate(THEME_STORAGE, ThemePreference.System);
        hilog.warn(DOMAIN, TAG, 'Could not apply appearance preference');
      }
    });

    // 先注册托盘图标，hideAbility 才有"已在状态栏"的前提
    this.setupTray();

    try {
      windowStage.on('windowStageClose', () => {
        hilog.info(DOMAIN, TAG, 'windowStageClose -> hideAbility');
        this.context.hideAbility().then(() => {
          hilog.info(DOMAIN, TAG, 'hideAbility OK');
        }).catch((error: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'hideAbility failed, fallback minimize: %{public}s', JSON.stringify(error));
          if (this.mainWindow) {
            this.mainWindow.minimize().catch((e: BusinessError) => {
              hilog.error(DOMAIN, TAG, 'minimize failed: %{public}s', JSON.stringify(e));
            });
          }
        });
        return true;
      });
      windowStage.getMainWindow((err: BusinessError, win: window.Window) => {
        if (!err.code) {
          this.mainWindow = win;
          hilog.info(DOMAIN, TAG, 'getMainWindow ok');
          this.startKeepAlive();
          // 开机自启场景：配置 autoHideOnLaunch=true 时延迟隐藏到托盘（托盘已注册）
          if (readAutoHide()) {
            setTimeout(() => {
              this.context.hideAbility().then(() => {
                hilog.info(DOMAIN, TAG, 'autoHideOnLaunch: hideAbility OK');
              }).catch((error: BusinessError) => {
                hilog.warn(DOMAIN, TAG, 'autoHideOnLaunch failed: %{public}s', JSON.stringify(error));
                if (this.mainWindow) this.mainWindow.minimize().catch(() => {});
              });
            }, 2000);
          }
        }
      });
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'windowStage setup failed: %{public}s', JSON.stringify(error));
    }
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
