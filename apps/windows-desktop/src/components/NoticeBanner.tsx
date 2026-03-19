import { createPortal } from "react-dom";
import type { Notice } from "../types/app";

type NoticeBannerProps = {
  notice: Notice | null;
};

export function NoticeBanner({ notice }: NoticeBannerProps) {
  if (!notice) {
    return null;
  }

  return createPortal(
    <div className={`notice ${notice.type}`} role="status" aria-live="polite">
      {notice.message}
    </div>,
    document.body,
  );
}
