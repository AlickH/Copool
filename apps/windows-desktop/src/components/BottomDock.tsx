import { useI18n } from "../i18n/I18nProvider";

type AppTab = "accounts" | "proxy" | "settings";

type BottomDockProps = {
  activeTab: AppTab;
  onSelectTab: (tab: AppTab) => void;
};

function AccountsIcon() {
  return (
    <svg className="bottomDockIcon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <rect x="4" y="4" width="7" height="7" rx="1.5" />
      <rect x="13" y="4" width="7" height="7" rx="1.5" />
      <rect x="4" y="13" width="7" height="7" rx="1.5" />
      <rect x="13" y="13" width="7" height="7" rx="1.5" />
    </svg>
  );
}

function ProxyIcon() {
  return (
    <svg className="bottomDockIcon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M7 7h10v4H7z" />
      <path d="M9 11v3" />
      <path d="M15 11v3" />
      <path d="M6 17h12" />
      <path d="M12 14v3" />
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg className="bottomDockIcon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M10.33 4.32c.43-1.76 2.91-1.76 3.34 0a1.72 1.72 0 0 0 2.57 1.06c1.54-.93 3.3.83 2.37 2.37a1.72 1.72 0 0 0 1.06 2.57c1.76.43 1.76 2.91 0 3.34a1.72 1.72 0 0 0-1.06 2.57c.93 1.54-.83 3.3-2.37 2.37a1.72 1.72 0 0 0-2.57 1.06c-.43 1.76-2.91 1.76-3.34 0a1.72 1.72 0 0 0-2.57-1.06c-1.54.93-3.3-.83-2.37-2.37a1.72 1.72 0 0 0-1.06-2.57c-1.76-.43-1.76-2.91 0-3.34a1.72 1.72 0 0 0 1.06-2.57c-.93-1.54.83-3.3 2.37-2.37.99.6 2.29.07 2.57-1.06Z" />
      <circle cx="12" cy="12" r="3.1" />
    </svg>
  );
}

export function BottomDock({
  activeTab,
  onSelectTab,
}: BottomDockProps) {
  const { copy } = useI18n();
  const accountActive = activeTab === "accounts";
  const proxyActive = activeTab === "proxy";
  const settingsActive = activeTab === "settings";

  return (
    <nav className="bottomDock" aria-label={copy.bottomDock.ariaLabel}>
      <button
        className={`bottomDockButton${accountActive ? " isActive" : ""}`}
        onClick={() => onSelectTab("accounts")}
        aria-label={copy.bottomDock.accounts}
        title={copy.bottomDock.accounts}
      >
        <AccountsIcon />
        <span className="bottomDockLabel">{copy.bottomDock.accounts}</span>
      </button>
      <button
        className={`bottomDockButton${proxyActive ? " isActive" : ""}`}
        onClick={() => onSelectTab("proxy")}
        aria-label={copy.bottomDock.proxy}
        title={copy.bottomDock.proxy}
      >
        <ProxyIcon />
        <span className="bottomDockLabel">{copy.bottomDock.proxy}</span>
      </button>
      <button
        className={`bottomDockButton${settingsActive ? " isActive" : ""}`}
        onClick={() => onSelectTab("settings")}
        aria-label={copy.bottomDock.settings}
        title={copy.bottomDock.settings}
      >
        <SettingsIcon />
        <span className="bottomDockLabel">{copy.bottomDock.settings}</span>
      </button>
    </nav>
  );
}
