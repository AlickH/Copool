import type { ThemeMode } from "../types/app";
import { useI18n } from "../i18n/I18nProvider";

type ThemeSwitchProps = {
  themeMode: ThemeMode;
  onToggle: () => void;
};

export function ThemeSwitch({ themeMode, onToggle }: ThemeSwitchProps) {
  const { copy } = useI18n();
  const isDark = themeMode === "dark";

  return (
    <label className="themeSwitch" aria-label={copy.settings.theme.switchAriaLabel}>
      <input type="checkbox" checked={isDark} onChange={onToggle} />
      <span className="themeSwitchTrack" aria-hidden="true">
        <span className="themeSwitchThumb" />
      </span>
      <span className="themeSwitchText">{isDark ? copy.settings.theme.dark : copy.settings.theme.light}</span>
    </label>
  );
}
