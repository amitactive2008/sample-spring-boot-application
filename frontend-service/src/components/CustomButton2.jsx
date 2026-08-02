import React from 'react';

const CustomButton2 = ({ children, color = 'mint', className = '', ...props }) => {
  const colorClasses = {
    mint: 'bg-[#2a9d8f] text-white hover:bg-[#21867a]',
    danger: 'bg-red-500 text-white hover:bg-red-600',
    warning: 'bg-yellow-500 text-white hover:bg-yellow-600',
    blue: 'bg-blue-500 text-white hover:bg-blue-600',
    gray: 'bg-gray-500 text-white hover:bg-gray-600',
  };

  return (
    <button
      className={`py-1.5 px-3 rounded-md font-semibold text-sm shadow-md border border-transparent
        transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-opacity-50
        disabled:opacity-50 disabled:cursor-not-allowed
        ${colorClasses[color] || colorClasses.mint} ${className}`}
      {...props}
    >
      {children}
    </button>
  );
};

export default CustomButton2;
