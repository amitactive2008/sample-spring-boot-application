import { validateIssue, validateLogin, validateRegistration } from './forms';

describe('form validation', () => {
  test('accepts valid login values', () => {
    expect(validateLogin({ email: 'user@example.com', password: 'pass' })).toEqual({});
  });

  test('requires valid login values', () => {
    expect(validateLogin({ email: 'invalid', password: '' })).toEqual({
      email: 'Invalid email',
      password: 'Password is required',
    });
  });

  test('enforces registration password rules', () => {
    expect(
      validateRegistration({
        email: 'user@example.com',
        password: 'Password1!',
        confirmPassword: 'different',
      })
    ).toEqual({ confirmPassword: 'Passwords must match' });
  });

  test('requires issue fields', () => {
    expect(validateIssue({ title: '', severity: '', priority: '' })).toEqual({
      title: 'Title is required',
      severity: 'Severity is required',
      priority: 'Priority is required',
    });
  });
});
