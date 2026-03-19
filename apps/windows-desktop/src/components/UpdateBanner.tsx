import { createPortal } from "react-dom";
import { useI18n } from "../i18n/I18nProvider";
import type { PendingUpdateInfo } from "../types/app";

type UpdateBannerProps = {
  open: boolean;
  pendingUpdate: PendingUpdateInfo | null;
  updateProgress: string | null;
  installingUpdate: boolean;
  onClose: () => void;
  onManualDownload: () => void;
  onRetryAutoDownload: () => void;
};

export function UpdateBanner({
  open,
  pendingUpdate,
  updateProgress,
  installingUpdate,
  onClose,
  onManualDownload,
  onRetryAutoDownload,
}: UpdateBannerProps) {
  const { copy } = useI18n();

  if (!open || !pendingUpdate) {
    return null;
  }

  return createPortal(
    <div className="updateOverlay" onClick={onClose}>
      <section
        className="updateDialog"
        role="dialog"
        aria-modal="true"
        aria-label={copy.updateDialog.ariaLabel}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="settingsHeader">
          <div>
            <h2>{copy.updateDialog.title(pendingUpdate.version)}</h2>
            <p>{copy.updateDialog.subtitle(pendingUpdate.currentVersion)}</p>
          </div>
          <button
            className="iconButton ghost"
            onClick={onClose}
            aria-label={copy.updateDialog.close}
            title={copy.common.close}
          >
            <svg className="iconGlyph" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <path d="m6 6 12 12" />
              <path d="M18 6 6 18" />
            </svg>
          </button>
        </div>

        <div className="updateText">
          {pendingUpdate.date && <span>{copy.updateDialog.publishedAt(pendingUpdate.date)}</span>}
          <span>{installingUpdate ? copy.updateDialog.autoDownloading : copy.updateDialog.autoPaused}</span>
        </div>

        <div className="updateDialogActions">
          <button className="ghost" onClick={onManualDownload}>
            {copy.updateDialog.manualDownload}
          </button>
          <button className="primary" onClick={onRetryAutoDownload} disabled={installingUpdate}>
            {installingUpdate ? copy.updateDialog.retryingAutoDownload : copy.updateDialog.retryAutoDownload}
          </button>
        </div>

        {updateProgress && <p className="updateProgress">{updateProgress}</p>}
        {pendingUpdate.body && <p className="updateBody">{pendingUpdate.body}</p>}
      </section>
    </div>,
    document.body,
  );
}
