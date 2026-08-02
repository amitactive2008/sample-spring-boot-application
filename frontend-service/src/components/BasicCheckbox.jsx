import React from 'react';

const BasicCheckbox = ({ id, name, checked, onChange, label, className = '', ...props }) => (
  <label className={`flex items-center cursor-pointer ${className}`} htmlFor={id || name}>
    <input
      id={id || name}
      name={name}
      type="checkbox"
      checked={checked}
      onChange={onChange}
      className="form-checkbox h-4 w-4 text-blue-600 transition duration-150 ease-in-out mr-2"
      {...props}
    />
    <span className="text-sm text-gray-700">{label}</span>
  </label>
);

export default BasicCheckbox;
