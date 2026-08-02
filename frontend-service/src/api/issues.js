import api from './axiosConfig';

// ─── Issues CRUD ───

export const createIssue = async (issueData) => {
  const response = await api.post('/issues', issueData);
  return response.data;
};

export const getIssues = async (params = {}) => {
  const response = await api.get('/issues', { params });
  return response.data;
};

export const getIssueById = async (id) => {
  const response = await api.get(`/issues/${id}`);
  return response.data;
};

export const updateIssue = async (id, issueData) => {
  const response = await api.put(`/issues/${id}`, issueData);
  return response.data;
};

export const updateIssueStatus = async (id, status) => {
  const response = await api.patch(`/issues/${id}/status`, { status });
  return response.data;
};

export const deleteIssue = async (id) => {
  const response = await api.delete(`/issues/${id}`);
  return response.data;
};

export const getIssueCountByStatus = async () => {
  const response = await api.get('/issues/count-by-status');
  return response.data;
};

export const getIssueStatusHistory = async (id) => {
  const response = await api.get(`/issues/${id}/history`);
  return response.data;
};
