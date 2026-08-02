import React from 'react';

// Simple glassmorphism tooltip using Tailwind utility classes.
// Usage: <Tooltip content="text"> <button>...</button> </Tooltip>
const Tooltip = ({ content, children, position = 'top' }) => {
  // positions: top (default), right, bottom, left
  const posClasses = {
    top: 'bottom-full left-1/2 -translate-x-1/2 mb-2',
    right: 'left-full top-1/2 -translate-y-1/2 ml-2',
    bottom: 'top-full left-1/2 -translate-x-1/2 mt-2',
    left: 'right-full top-1/2 -translate-y-1/2 mr-2',
  };

  return (
    <span className="relative inline-flex group">
      {children}
      <span
        role="tooltip"
        className={`pointer-events-none opacity-0 group-hover:opacity-100 group-focus:opacity-100 transition-opacity duration-150 ease-out z-50 absolute ${posClasses[position]} w-max max-w-xs`}
      >
        <span className="whitespace-normal text-xs text-gray-800 bg-white/60 backdrop-blur-md px-3 py-2 rounded-lg shadow-md border border-white/40">
          {content}
        </span>
      </span>
    </span>
  );
};

export default Tooltip;
