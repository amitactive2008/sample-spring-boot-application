import React, { useEffect } from 'react';
import { FaCheckCircle, FaExclamationTriangle, FaInfoCircle, FaTimes, FaTimesCircle } from 'react-icons/fa';

const theme = {
  info: {
    border: 'border-blue-200', bg: 'bg-blue-50', text: 'text-blue-800', icon: 'text-blue-500',
    btnBg: 'bg-blue-600 hover:bg-blue-700 focus:ring-blue-500',
    btnCancel: 'bg-gray-100 hover:bg-gray-200 text-gray-700',
    iconComponent: FaInfoCircle,
  },
  success: {
    border: 'border-green-200', bg: 'bg-green-50', text: 'text-green-800', icon: 'text-green-500',
    btnBg: 'bg-green-600 hover:bg-green-700 focus:ring-green-500',
    btnCancel: 'bg-gray-100 hover:bg-gray-200 text-gray-700',
    iconComponent: FaCheckCircle,
  },
  warning: {
    border: 'border-yellow-200', bg: 'bg-yellow-50', text: 'text-yellow-800', icon: 'text-yellow-500',
    btnBg: 'bg-yellow-600 hover:bg-yellow-700 focus:ring-yellow-500',
    btnCancel: 'bg-gray-100 hover:bg-gray-200 text-gray-700',
    iconComponent: FaExclamationTriangle,
  },
  danger: {
    border: 'border-red-200', bg: 'bg-red-50', text: 'text-red-800', icon: 'text-red-500',
    btnBg: 'bg-red-600 hover:bg-red-700 focus:ring-red-500',
    btnCancel: 'bg-gray-100 hover:bg-gray-200 text-gray-700',
    iconComponent: FaTimesCircle,
  },
};

const BasicAlertBox = ({
  open,
  message,
  title,
  onConfirm,
  onCancel,
  confirmText = 'OK',
  cancelText = '',
  type = 'info',
  autoClose = false,
  showCloseButton = true,
}) => {
  const t = theme[type] || theme.info;
  const IconComponent = t.iconComponent;

  useEffect(() => {
    if (open && autoClose && onConfirm) {
      const timer = setTimeout(() => onConfirm(), 3000);
      return () => clearTimeout(timer);
    }
  }, [open, autoClose, onConfirm]);

  useEffect(() => {
    const handleEscape = (e) => {
      if (e.key === 'Escape' && open) {
        onCancel ? onCancel() : onConfirm && onConfirm();
      }
    };
    if (open) {
      document.addEventListener('keydown', handleEscape);
      document.body.style.overflow = 'hidden';
    }
    return () => {
      document.removeEventListener('keydown', handleEscape);
      document.body.style.overflow = 'unset';
    };
  }, [open, onConfirm, onCancel]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-[9999] flex items-center justify-center p-4">
      <div className="fixed inset-0 bg-black/40 backdrop-blur-sm" onClick={onCancel || onConfirm} />
      <div className={`relative w-full max-w-sm rounded-2xl shadow-2xl border ${t.border} ${t.bg} overflow-hidden animate-[fadeIn_0.2s_ease-out]`}>
        {/* Header row: icon + close */}
        <div className="flex items-center justify-between px-5 pt-5 pb-0">
          <div className={`${t.icon}`}>
            <IconComponent size={28} />
          </div>
          {showCloseButton && (
            <button
              onClick={onCancel || onConfirm}
              className="text-gray-400 hover:text-gray-600 transition-colors p-1"
            >
              <FaTimes size={14} />
            </button>
          )}
        </div>

        {/* Message */}
        <div className="px-5 pt-3 pb-5">
          {title && <h3 className={`text-base font-bold mb-1 ${t.text}`}>{title}</h3>}
          <p className={`text-sm ${t.text} opacity-80 leading-relaxed`}>{message}</p>
        </div>

        {/* Buttons - full width */}
        <div className="px-5 pb-5 flex flex-col gap-2">
          <button
            onClick={onConfirm}
            className={`w-full py-2.5 rounded-lg text-sm font-bold text-white transition-all focus:outline-none focus:ring-2 ${t.btnBg}`}
          >
            {confirmText}
          </button>
          {cancelText && (
            <button
              onClick={onCancel}
              className={`w-full py-2.5 rounded-lg text-sm font-semibold transition-colors ${t.btnCancel}`}
            >
              {cancelText}
            </button>
          )}
        </div>
      </div>
    </div>
  );
};

export default BasicAlertBox;
