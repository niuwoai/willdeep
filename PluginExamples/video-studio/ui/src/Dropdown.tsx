import { useEffect, useId, useRef, useState } from 'react';
import type { ReactElement } from 'react';

export interface DropdownOption {
  value: string;
  label: string;
  hint?: string;
}

interface DropdownProps {
  value: string;
  options: DropdownOption[];
  onChange: (value: string) => void;
  ariaLabel?: string;
  placeholder?: string;
  /** 末尾多一项「自定义…」，选中后变成输入框，可以直接打一个不在清单里的值。 */
  allowCustom?: boolean;
  customLabel?: string;
  customPlaceholder?: string;
  disabled?: boolean;
}

const CUSTOM_VALUE = '__custom__';

/**
 * 插件页自己的下拉。
 *
 * 为什么不用原生 `<select>`：WKWebView 里它是系统控件，跟这一页的圆角、
 * 描边、字重全对不上，暗色主题下尤其突兀，而且下拉面板的样式一点也改不了。
 *
 * 交互按可及性最低要求做齐：`role="listbox"` 加 `aria-activedescendant`，
 * 上下键移动、Enter/Space 选中、Esc 关闭、失焦关闭。
 */
export function Dropdown({
  value,
  options,
  onChange,
  ariaLabel,
  placeholder,
  allowCustom = false,
  customLabel = 'Custom…',
  customPlaceholder,
  disabled = false,
}: DropdownProps): ReactElement {
  const [open, setOpen] = useState(false);
  const [highlighted, setHighlighted] = useState(0);
  // 当前值不在清单里，说明用户之前手填过，直接进输入态而不是显示空白。
  const [custom, setCustom] = useState(
    () => allowCustom && value !== '' && !options.some((item) => item.value === value)
  );
  const containerRef = useRef<HTMLDivElement | null>(null);
  const listID = useId();

  useEffect(() => {
    if (!open) return;
    function onPointerDown(event: MouseEvent) {
      if (!containerRef.current?.contains(event.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', onPointerDown);
    return () => document.removeEventListener('mousedown', onPointerDown);
  }, [open]);

  const entries: DropdownOption[] = allowCustom
    ? [...options, { value: CUSTOM_VALUE, label: customLabel }]
    : options;
  const selected = options.find((item) => item.value === value);

  if (custom) {
    return (
      <div className="dropdown custom" ref={containerRef}>
        <input
          className="dropdown-input"
          value={value}
          placeholder={customPlaceholder ?? placeholder}
          aria-label={ariaLabel}
          disabled={disabled}
          autoFocus
          onChange={(event) => onChange(event.target.value)}
        />
        <button
          type="button"
          className="dropdown-revert"
          aria-label={customLabel}
          onClick={() => {
            setCustom(false);
            onChange(options[0]?.value ?? '');
          }}
        >
          ⌄
        </button>
      </div>
    );
  }

  function commit(entry: DropdownOption) {
    setOpen(false);
    if (entry.value === CUSTOM_VALUE) {
      setCustom(true);
      onChange('');
      return;
    }
    onChange(entry.value);
  }

  return (
    <div className="dropdown" ref={containerRef}>
      <button
        type="button"
        className="dropdown-trigger"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={ariaLabel}
        disabled={disabled}
        onClick={() => {
          if (disabled) return;
          setOpen((current) => !current);
          setHighlighted(Math.max(0, entries.findIndex((item) => item.value === value)));
        }}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            if (!open) {
              setOpen(true);
              return;
            }
            const step = event.key === 'ArrowDown' ? 1 : -1;
            setHighlighted((current) => (current + step + entries.length) % entries.length);
          } else if (open && (event.key === 'Enter' || event.key === ' ')) {
            event.preventDefault();
            const entry = entries[highlighted];
            if (entry) commit(entry);
          } else if (event.key === 'Escape' && open) {
            event.preventDefault();
            setOpen(false);
          }
        }}
      >
        <span className={selected ? '' : 'muted'}>{selected?.label ?? placeholder ?? ''}</span>
        <svg viewBox="0 0 12 12" aria-hidden="true" width="10" height="10">
          <path d="M2.5 4.5 6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.4" />
        </svg>
      </button>
      {open && (
        <div className="dropdown-menu" role="listbox" id={listID} aria-label={ariaLabel}>
          {entries.map((entry, index) => (
            <button
              type="button"
              role="option"
              aria-selected={entry.value === value}
              key={entry.value}
              className={[
                entry.value === value ? 'chosen' : '',
                index === highlighted ? 'highlighted' : '',
              ].filter(Boolean).join(' ')}
              onMouseEnter={() => setHighlighted(index)}
              onMouseDown={(event) => {
                event.preventDefault();
                commit(entry);
              }}
            >
              <span>{entry.label}</span>
              {entry.hint ? <small>{entry.hint}</small> : null}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
