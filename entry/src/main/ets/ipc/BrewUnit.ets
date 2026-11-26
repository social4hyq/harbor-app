// brew 服务失效判据（单一来源，供 IpcServer 与 Index 共用）
// 对齐 brew services cleanup / systemd：以「后端 unit 文件是否还在磁盘」为权威信号，
// 仅 brew 管理的 opt/ 路径纳入，手工 unit（如 ~/.config/daemonbox/units/）一律跳过。
import fileIo from '@ohos.file.fs';

const BREW_OPT = '/storage/Users/currentUser/.harmonybrew/opt/';

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
