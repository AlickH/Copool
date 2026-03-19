import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type InputHTMLAttributes,
} from "react";
import { createPortal } from "react-dom";
import { useI18n } from "../i18n/I18nProvider";
import type { AuthJsonImportInput } from "../types/app";

type AddAccountTab = "oauth" | "upload";

type AddAccountDialogProps = {
  open: boolean;
  startingAdd: boolean;
  addFlowActive: boolean;
  importingUpload: boolean;
  onStartOauth: () => Promise<void>;
  onImportFiles: (items: AuthJsonImportInput[]) => Promise<void>;
  onClose: () => void;
};

const folderPickerAttributes = {
  webkitdirectory: "",
  directory: "",
} as unknown as InputHTMLAttributes<HTMLInputElement>;

export function AddAccountDialog({
  open,
  startingAdd,
  addFlowActive,
  importingUpload,
  onStartOauth,
  onImportFiles,
  onClose,
}: AddAccountDialogProps) {
  const { copy } = useI18n();
  const [activeTab, setActiveTab] = useState<AddAccountTab>("oauth");
  const [selectedFiles, setSelectedFiles] = useState<File[]>([]);
  const [readingFiles, setReadingFiles] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const folderInputRef = useRef<HTMLInputElement>(null);

  const actionLocked = startingAdd || addFlowActive || importingUpload || readingFiles;
  const closeBlocked = startingAdd || importingUpload || readingFiles;

  useEffect(() => {
    if (!open) {
      return;
    }

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !closeBlocked) {
        onClose();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [closeBlocked, onClose, open]);

  const stageTitle =
    startingAdd && !addFlowActive ? copy.addAccount.launchingTitle : copy.addAccount.watchingTitle;
  const stageDetail =
    startingAdd && !addFlowActive
      ? copy.addAccount.launchingDetail
      : copy.addAccount.watchingDetail;
  const tabOptions: Array<{ id: AddAccountTab; label: string }> = [
    { id: "oauth", label: copy.addAccount.oauthTab },
    { id: "upload", label: copy.addAccount.uploadTab },
  ];

  const selectedSummary = useMemo(() => {
    if (selectedFiles.length === 0) {
      return copy.addAccount.uploadNoJsonFiles;
    }

    const firstPath = selectedFiles[0]?.webkitRelativePath || selectedFiles[0]?.name || "";
    if (selectedFiles.length === 1) {
      return firstPath;
    }

    return copy.addAccount.uploadFileSummary(firstPath, selectedFiles.length);
  }, [copy.addAccount, selectedFiles]);

  if (!open) {
    return null;
  }

  const mergeSelectedFiles = (incomingFiles: File[]) => {
    setSelectedFiles((current) => {
      const nextMap = new Map<string, File>();
      for (const file of current) {
        const key = file.webkitRelativePath || file.name;
        nextMap.set(key, file);
      }
      for (const file of incomingFiles) {
        const key = file.webkitRelativePath || file.name;
        nextMap.set(key, file);
      }
      return Array.from(nextMap.entries())
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([, file]) => file);
    });
  };

  const handleFilesPicked = (event: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.currentTarget.files ?? []).filter((file) =>
      file.name.toLowerCase().endsWith(".json"),
    );
    if (files.length > 0) {
      mergeSelectedFiles(files);
    }
    event.currentTarget.value = "";
  };

  const handleImportFiles = async () => {
    if (actionLocked || selectedFiles.length === 0) {
      return;
    }

    setReadingFiles(true);
    try {
      const items = await Promise.all(
        selectedFiles.map(async (file) => ({
          source: file.webkitRelativePath || file.name,
          content: await file.text(),
          label: null,
        })),
      );
      await onImportFiles(items);
    } finally {
      setReadingFiles(false);
    }
  };

  return createPortal(
    <div
      className="settingsOverlay"
      onClick={() => {
        if (!closeBlocked) {
          onClose();
        }
      }}
    >
      <section
        className="settingsDialog addAuthDialog"
        role="dialog"
        aria-modal="true"
        aria-label={copy.addAccount.dialogAriaLabel}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="settingsHeader">
          <div>
            <h2>{copy.addAccount.dialogTitle}</h2>
          </div>
          <button
            className="iconButton ghost"
            onClick={onClose}
            title={copy.common.close}
            disabled={closeBlocked}
            aria-label={copy.common.close}
          >
            <svg className="iconGlyph" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <path d="m6 6 12 12" />
              <path d="M18 6 6 18" />
            </svg>
          </button>
        </div>

        <div className="addAccountTabs" role="tablist" aria-label={copy.addAccount.tabsAriaLabel}>
          {tabOptions.map((tab) => {
            const active = tab.id === activeTab;
            return (
              <button
                key={tab.id}
                type="button"
                role="tab"
                aria-selected={active}
                className={`addAccountTab${active ? " isActive" : ""}`}
                onClick={() => setActiveTab(tab.id)}
                disabled={actionLocked}
              >
                <strong>{tab.label}</strong>
              </button>
            );
          })}
        </div>

        {activeTab === "oauth" ? (
          <div className="addAccountPanel">
            <div className="addOauthCard">
              {(startingAdd || addFlowActive) ? (
                <>
                  <svg
                    className="iconGlyph isSpinning addAuthSpinner addOauthSpinner"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                    focusable="false"
                  >
                    <path d="M21 12a9 9 0 1 1-2.64-6.36" />
                  </svg>
                  <strong>{stageTitle}</strong>
                  <p>{stageDetail}</p>
                  <button className="ghost" onClick={onClose}>
                    {copy.addAccount.cancelListening}
                  </button>
                </>
              ) : (
                <button className="primary addOauthPrimary" onClick={() => void onStartOauth()}>
                  {copy.addAccount.oauthStart}
                </button>
              )}
            </div>
          </div>
        ) : null}

        {activeTab === "upload" ? (
          <div className="addAccountPanel">
            <input
              ref={fileInputRef}
              className="visuallyHidden"
              type="file"
              multiple
              accept=".json,application/json"
              onChange={handleFilesPicked}
            />
            <input
              ref={folderInputRef}
              className="visuallyHidden"
              type="file"
              multiple
              accept=".json,application/json"
              onChange={handleFilesPicked}
              {...folderPickerAttributes}
            />

            <div className="addUploadCard">
              <div className="addUploadPickerRow">
                <button
                  className="ghost"
                  onClick={() => fileInputRef.current?.click()}
                  disabled={actionLocked}
                >
                  {copy.addAccount.uploadChooseFiles}
                </button>
                <button
                  className="ghost"
                  onClick={() => folderInputRef.current?.click()}
                  disabled={actionLocked}
                >
                  {copy.addAccount.uploadChooseFolder}
                </button>
              </div>

              <div className="addUploadSummary">
                <strong>
                  {selectedFiles.length > 0
                    ? copy.addAccount.uploadSelectedCount(selectedFiles.length)
                    : copy.addAccount.uploadNoFiles}
                </strong>
                <p>{selectedSummary}</p>
              </div>

              <button
                className="primary addUploadPrimary"
                onClick={() => void handleImportFiles()}
                disabled={actionLocked || selectedFiles.length === 0}
              >
                {importingUpload || readingFiles
                  ? copy.addAccount.uploadImporting
                  : copy.addAccount.uploadStartImport}
              </button>
            </div>
          </div>
        ) : null}
      </section>
    </div>,
    document.body,
  );
}
