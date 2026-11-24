import { StatusBarViewExtensionAbility } from '@kit.StatusBarExtensionKit';
import { UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HarborStatusBar';

export default class StatusBarAbility extends StatusBarViewExtensionAbility {
  onCreate(): void {
    hilog.info(0x0000, TAG, 'onCreate');
  }
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    hilog.info(0x0000, TAG, 'onSessionCreate');
  }
  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy');
  }
}
