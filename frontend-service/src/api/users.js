import api from './axiosConfig';

// ─── User Management (Admin Only) ───

export const getAllUsers = async () => {
  const response = await api.get('/auth/users');
  return response.data;
};

export const getUserById = async (id) => {
  const response = await api.get(`/auth/users/${id}`);
  return response.data;
};

export const deleteUser = async (id) => {
  const response = await api.delete(`/auth/users/${id}`);
  return response.data;
};
