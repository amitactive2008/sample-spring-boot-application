import React, { useState } from 'react';
import styled from 'styled-components';
import { FaEye, FaEyeSlash } from 'react-icons/fa';

const InputContainer = styled.div`
  position: relative;
  width: 100%;
`;

const StyledInput = styled.input`
  width: 100%;
  padding: 12px 16px 12px 40px;
  font-size: 0.75rem;
  border: 2px solid #1a365d;
  border-radius: 0.375rem;
  background-color: white;
  transition: box-shadow 0.2s ease-in-out, border-color 0.2s ease-in-out;
  box-shadow: 0 1px 2px 0 rgba(0, 0, 0, 0.05);
  outline: none;
  line-height: 1;

  &:focus {
    border-color: #1a365d;
    box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
    outline: none;
  }

  &:not(:placeholder-shown) {
    padding-top: 12px;
    padding-bottom: 12px;
  }
`;

const StyledLabel = styled.label`
  position: absolute;
  left: 40px;
  top: 50%;
  transform: translateY(-50%);
  font-size: 0.75rem;
  font-weight: 500;
  color: #a0aec0;
  background-color: white;
  padding: 0 4px;
  transition: all 0.2s ease-in-out;
  pointer-events: none;

  ${StyledInput}:focus + &,
  ${StyledInput}:not(:placeholder-shown) + & {
    top: -10px;
    font-size: 0.625rem;
    color: #1a365d;
    transform: translateY(0);
    left: 8px;
  }
`;

const InnerIconWrapper = styled.div`
  position: absolute;
  left: 12px;
  top: 50%;
  transform: translateY(-50%);
  color: ${props => props.$isActive ? '#1a365d' : '#a0aec0'};
  transition: color 0.2s ease-in-out;
`;

const TogglePasswordButton = styled.button`
  position: absolute;
  right: 12px;
  top: 50%;
  transform: translateY(-50%);
  color: #a0aec0;
  cursor: pointer;
  background: none;
  border: none;
  padding: 0;
  &:hover {
    color: #4a5568;
  }
`;

const CustomTextField = ({
  id,
  name,
  label,
  type = 'text',
  value,
  onChange,
  error,
  touched,
  icon: Icon,
  ...rest
}) => {
  const [showPassword, setShowPassword] = useState(false);
  const isPassword = type === 'password';
  const inputType = isPassword ? (showPassword ? 'text' : 'password') : type;
  const isActive = !!value;

  return (
    <div className="flex flex-col mb-2">
      <InputContainer>
        {Icon && (
          <InnerIconWrapper $isActive={isActive}>
            <Icon size={14} />
          </InnerIconWrapper>
        )}
        <StyledInput
          id={id || name}
          name={name}
          type={inputType}
          value={value}
          onChange={onChange}
          placeholder=" "
          {...rest}
        />
        <StyledLabel htmlFor={id || name}>{label}</StyledLabel>
        {isPassword && (
          <TogglePasswordButton
            type="button"
            onClick={() => setShowPassword(!showPassword)}
            tabIndex={-1}
          >
            {showPassword ? <FaEyeSlash size={14} /> : <FaEye size={14} />}
          </TogglePasswordButton>
        )}
      </InputContainer>
      {error && touched && (
        <span className="text-red-500 text-[10px] mt-1">{error}</span>
      )}
    </div>
  );
};

export default CustomTextField;
