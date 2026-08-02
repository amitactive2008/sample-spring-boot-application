import React from 'react';

const CustomButton = ({ children, className = '', ...props }) => {
  return (
    <button
      className={`w-full py-2.5 px-4 bg-[#1a365d] text-white text-xs font-bold rounded-lg mt-4 mb-2
        hover:bg-[#13294b] active:bg-[#0f2038] transition-all duration-200
        focus:outline-none focus:ring-2 focus:ring-[#1a365d] focus:ring-opacity-50
        shadow-md hover:shadow-xl active:shadow-md
        transform hover:-translate-y-0.5 active:transform-none
        disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:translate-y-0 ${className}`}
      {...props}
    >
      {children}
    </button>
  );
};

export default CustomButton;
