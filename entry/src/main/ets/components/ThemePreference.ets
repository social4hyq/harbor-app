import common from '@ohos.app.ability.common';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import preferences from '@ohos.data.preferences';

export enum ThemePreference { System = 'system', Light = 'light', Dark = 'dark' }

export const THEME_STORAGE = 'harborTheme';
const THEME_KEY = 'appearance';

function themeStore(context: common.UIAbilityContext): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: 'harbor_settings' });
}

export function readTheme(context: common.UIAbilityContext): ThemePreference {
  const value = themeStore(context).getSync(THEME_KEY, ThemePreference.System);
  if (value === ThemePreference.Light || value === ThemePreference.Dark) return value;
  return ThemePreference.System;
}

export function applyTheme(context: common.UIAbilityContext, value: ThemePreference): void {
  let mode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  if (value === ThemePreference.Light) mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  if (value === ThemePreference.Dark) mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  context.getApplicationContext().setColorMode(mode);
}

export async function saveTheme(context: common.UIAbilityContext, value: ThemePreference): Promise<void> {
  const store = themeStore(context);
  store.putSync(THEME_KEY, value);
  await store.flush();
}
