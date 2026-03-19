import { createPortal } from "react-dom";

import { useI18n } from "../i18n/I18nProvider";
import type { RemoteDeployProgress, RemoteDeployStage } from "../types/app";

type RemoteDeployProgressToastProps = {
  progress: RemoteDeployProgress | null;
};

function getStageLabel(stage: RemoteDeployStage, copy: ReturnType<typeof useI18n>["copy"]) {
  const proxyCopy = copy.apiProxy;
  switch (stage) {
    case "validating":
      return proxyCopy.remoteDeployStageValidating;
    case "detectingPlatform":
      return proxyCopy.remoteDeployStageDetectingPlatform;
    case "preparingBuilder":
      return proxyCopy.remoteDeployStagePreparingBuilder;
    case "buildingBinary":
      return proxyCopy.remoteDeployStageBuildingBinary;
    case "preparingFiles":
      return proxyCopy.remoteDeployStagePreparingFiles;
    case "uploadingBinary":
      return proxyCopy.remoteDeployStageUploadingBinary;
    case "uploadingAccounts":
      return proxyCopy.remoteDeployStageUploadingAccounts;
    case "uploadingService":
      return proxyCopy.remoteDeployStageUploadingService;
    case "installingService":
      return proxyCopy.remoteDeployStageInstallingService;
    case "verifying":
      return proxyCopy.remoteDeployStageVerifying;
    default:
      return proxyCopy.remoteDeployStageValidating;
  }
}

export function RemoteDeployProgressToast({ progress }: RemoteDeployProgressToastProps) {
  const { copy } = useI18n();
  if (!progress) {
    return null;
  }

  const stageLabel = getStageLabel(progress.stage, copy);
  const boundedProgress = Math.max(6, Math.min(100, Math.round(progress.progress)));

  return createPortal(
    <div className="taskProgressToast" role="status" aria-live="polite" aria-busy="true">
      <div className="taskProgressHeader">
        <strong>{copy.apiProxy.remoteDeployProgressTitle(progress.label)}</strong>
        <span>{boundedProgress}%</span>
      </div>
      <div className="taskProgressTrack" aria-hidden="true">
        <span className="taskProgressFill" style={{ width: `${boundedProgress}%` }} />
      </div>
      <div className="taskProgressBody">
        <p className="taskProgressStage">{stageLabel}</p>
        {progress.detail ? <code className="taskProgressDetail">{progress.detail}</code> : null}
      </div>
    </div>,
    document.body,
  );
}
