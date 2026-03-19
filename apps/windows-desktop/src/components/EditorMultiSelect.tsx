import { createPortal } from "react-dom";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "../i18n/I18nProvider";

export type MultiSelectOption<T extends string> = {
  id: T;
  label: string;
};

type EditorMultiSelectProps<T extends string> = {
  options: MultiSelectOption<T>[];
  value: T | null;
  disabled?: boolean;
  ariaLabel?: string;
  placeholder?: string;
  className?: string;
  onChange: (next: T) => void;
};

export function EditorMultiSelect<T extends string>({
  options,
  value,
  disabled = false,
  ariaLabel,
  placeholder,
  className,
  onChange,
}: EditorMultiSelectProps<T>) {
  const { copy } = useI18n();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const [menuPosition, setMenuPosition] = useState<{ top: number; left: number; width: number } | null>(
    null,
  );

  const selected = useMemo(
    () => options.find((option) => option.id === value) ?? null,
    [options, value],
  );

  const updateMenuPosition = useCallback(() => {
    const trigger = triggerRef.current;
    if (!trigger) {
      return;
    }
    const rect = trigger.getBoundingClientRect();
    setMenuPosition({
      top: rect.bottom + 8,
      left: rect.left,
      width: rect.width,
    });
  }, []);

  useEffect(() => {
    if (!open) {
      return;
    }

    updateMenuPosition();

    const onPointerDown = (event: MouseEvent) => {
      const target = event.target as Node;
      const hitTrigger = rootRef.current?.contains(target);
      const hitMenu = menuRef.current?.contains(target);
      if (!hitTrigger && !hitMenu) {
        setOpen(false);
      }
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false);
      }
    };
    const onViewportChange = () => {
      updateMenuPosition();
    };

    window.addEventListener("mousedown", onPointerDown);
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("resize", onViewportChange);
    window.addEventListener("scroll", onViewportChange, true);
    return () => {
      window.removeEventListener("mousedown", onPointerDown);
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("resize", onViewportChange);
      window.removeEventListener("scroll", onViewportChange, true);
    };
  }, [open, updateMenuPosition]);

  const selectOption = (id: T) => {
    onChange(id);
    setOpen(false);
  };

  const effectiveAriaLabel = ariaLabel ?? copy.editorPicker.ariaLabel;
  const effectivePlaceholder = placeholder ?? copy.editorPicker.placeholder;

  return (
    <div
      ref={rootRef}
      className={`editorPicker${open ? " isOpen" : ""}${disabled ? " isDisabled" : ""}${
        className ? ` ${className}` : ""
      }`}
    >
      <button
        ref={triggerRef}
        type="button"
        className="editorPickerTrigger"
        disabled={disabled}
        onClick={() => {
          if (disabled) {
            return;
          }
          updateMenuPosition();
          setOpen((prev) => !prev);
        }}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={effectiveAriaLabel}
      >
        <div className="editorPickerValue">
          <span className={selected ? "editorPickerLabel" : "editorPickerPlaceholder"}>
            {selected?.label ?? effectivePlaceholder}
          </span>
        </div>
        <svg className="editorChevron" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
          <path d="m6 9 6 6 6-6" />
        </svg>
      </button>

      {open &&
        !disabled &&
        menuPosition &&
        createPortal(
          <div
            ref={menuRef}
            className="editorPickerMenu"
            style={{
              top: menuPosition.top,
              left: menuPosition.left,
              width: menuPosition.width,
            }}
            role="listbox"
            aria-multiselectable="false"
            onMouseDown={(event) => event.stopPropagation()}
            onClick={(event) => event.stopPropagation()}
          >
            {options.map((option) => {
              const isSelected = option.id === value;
              return (
                <button
                  key={option.id}
                  type="button"
                  className={`editorOption${isSelected ? " isSelected" : ""}`}
                  role="option"
                  aria-selected={isSelected}
                  onClick={() => selectOption(option.id)}
                >
                  <span className="editorOptionLabel">{option.label}</span>
                </button>
              );
            })}
          </div>,
          document.body,
        )}
    </div>
  );
}
