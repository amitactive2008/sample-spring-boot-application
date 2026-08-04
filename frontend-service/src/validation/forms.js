const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const SPECIAL_CHARACTER_PATTERN = /[@$!%*?&\-_.#]/;

const validateEmail = (email) => {
  const normalizedEmail = email?.trim() || '';

  if (!normalizedEmail) {
    return 'Email is required';
  }
  if (!EMAIL_PATTERN.test(normalizedEmail)) {
    return 'Invalid email';
  }
  if (normalizedEmail.length > 254) {
    return 'Email is too long';
  }
  return undefined;
};

export const validateLogin = ({ email, password }) => {
  const errors = {};
  const emailError = validateEmail(email);

  if (emailError) {
    errors.email = emailError;
  }
  if (!password) {
    errors.password = 'Password is required';
  } else if (password.length < 4) {
    errors.password = 'Password must be at least 4 characters';
  }

  return errors;
};

export const validateRegistration = ({ email, password, confirmPassword }) => {
  const errors = {};
  const emailError = validateEmail(email);

  if (emailError) {
    errors.email = emailError;
  }

  if (!password) {
    errors.password = 'Password is required';
  } else if (password.length < 8) {
    errors.password = 'Password must be at least 8 characters';
  } else if (!/[a-z]/.test(password)) {
    errors.password = 'Password must contain at least one lowercase letter';
  } else if (!/[A-Z]/.test(password)) {
    errors.password = 'Password must contain at least one uppercase letter';
  } else if (!/[0-9]/.test(password)) {
    errors.password = 'Password must contain at least one number';
  } else if (!SPECIAL_CHARACTER_PATTERN.test(password)) {
    errors.password =
      'Password must contain at least one special character (@ $ ! % * ? & - _ . #)';
  }

  if (!confirmPassword) {
    errors.confirmPassword = 'Confirm password is required';
  } else if (confirmPassword !== password) {
    errors.confirmPassword = 'Passwords must match';
  }

  return errors;
};

export const validateIssue = ({ title, severity, priority }) => {
  const errors = {};

  if (!title) {
    errors.title = 'Title is required';
  }
  if (!severity) {
    errors.severity = 'Severity is required';
  }
  if (!priority) {
    errors.priority = 'Priority is required';
  }

  return errors;
};
