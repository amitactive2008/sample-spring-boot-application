
import api from './axiosConfig';

// ─── Auth API ───
export const registerUser = async (email, password) => {
  const response = await api.post('/auth/register', { email, password });
  return response.data;
};

export const loginUser = async (email, password) => {
  const response = await api.post('/auth/login', { email, password });
  return response.data;
};

// ─── Helpers ───
const STORAGE = localStorage;

export const saveAuthData = (tokenResponse) => {
  // tokenResponse expected to contain { accessToken, role, email }
  STORAGE.setItem('authToken', tokenResponse.accessToken);
  STORAGE.setItem(
    'userData',
    JSON.stringify({ role: tokenResponse.role, email: tokenResponse.email })
  );
};

export const isAuthenticated = () => !!STORAGE.getItem('authToken');

export const getUserData = () => {
  const data = STORAGE.getItem('userData');
  return data ? JSON.parse(data) : null;
};

export const getUserRole = () => getUserData()?.role || null;

export const getUserEmail = () => getUserData()?.email || null;

export const logout = () => {
  STORAGE.removeItem('authToken');
  STORAGE.removeItem('userData');

  //signal other tabs reliably
  STORAGE.setItem('logout', String(Date.now()));

  window.location.replace('/login');
};
