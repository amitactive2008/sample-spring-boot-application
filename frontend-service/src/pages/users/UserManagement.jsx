import React, { useState, useEffect } from 'react';
import { FaTrash, FaUserShield, FaUser } from 'react-icons/fa';
import { getAllUsers, deleteUser } from '../../api/users';
import DashboardLayout from '../../components/layout/DashboardLayout';
import BasicTable from '../../components/BasicTable';
import BasicAlertBox from '../../components/BasicAlertBox';
import CustomButton2 from '../../components/CustomButton2';

const UserManagement = ({ sidebarItems }) => {
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [deleteAlert, setDeleteAlert] = useState({ open: false, userId: null, email: '' });
  const [alert, setAlert] = useState({ open: false, message: '', type: 'info', title: '' });

  useEffect(() => {
    fetchUsers();
  }, []);

  const fetchUsers = async () => {
    try {
      setLoading(true);
      const data = await getAllUsers();
      setUsers(Array.isArray(data) ? data : []);
    } catch (error) {
      console.error('Failed to fetch users:', error);
      setAlert({ open: true, message: 'Failed to load users', type: 'danger', title: 'Error' });
    } finally {
      setLoading(false);
    }
  };

  const handleDelete = async () => {
    try {
      await deleteUser(deleteAlert.userId);
      setDeleteAlert({ open: false, userId: null, email: '' });
      setAlert({ open: true, message: 'User deleted successfully', type: 'success', title: 'Deleted' });
      fetchUsers();
    } catch (error) {
      const msg = error.response?.data?.message || 'Failed to delete user';
      setAlert({ open: true, message: msg, type: 'danger', title: 'Error' });
    }
  };

  const columns = [
    { key: 'id', label: 'ID' },
    {
      key: 'email',
      label: 'Email',
      render: (row) => (
        <div className="flex items-center gap-2">
          {row.role === 'ADMIN' ? <FaUserShield className="text-indigo-500" /> : <FaUser className="text-gray-400" />}
          <span className="font-medium">{row.email}</span>
        </div>
      ),
    },
    {
      key: 'role',
      label: 'Role',
      render: (row) => (
        <span className={`px-2 py-0.5 rounded-full text-xs font-bold ${
          row.role === 'ADMIN' ? 'bg-indigo-100 text-indigo-700' : 'bg-gray-100 text-gray-700'
        }`}>
          {row.role}
        </span>
      ),
    },
  ];

  return (
    <DashboardLayout userRole="ADMIN" sidebarItems={sidebarItems}>
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800">User Management</h1>
          <p className="text-sm text-gray-500 mt-1">{users.length} registered users</p>
        </div>
      </div>

      {/* Table */}
      <BasicTable
        columns={columns}
        data={users}
        loading={loading}
        emptyMessage="No users found"
        actions={(row) => (
          <div className="flex items-center gap-1">
            <CustomButton2
              color="danger"
              className="!py-1 !px-2 !text-xs"
              onClick={() => setDeleteAlert({ open: true, userId: row.id, email: row.email })}
              disabled={row.role === 'ADMIN'}
              title={row.role === 'ADMIN' ? 'Cannot delete admin' : 'Delete user'}
            >
              <FaTrash />
            </CustomButton2>
          </div>
        )}
      />

      {/* Delete Confirmation */}
      <BasicAlertBox
        open={deleteAlert.open}
        title="Delete User"
        message={`Are you sure you want to delete user "${deleteAlert.email}"? This action cannot be undone.`}
        type="danger"
        onConfirm={handleDelete}
        onCancel={() => setDeleteAlert({ open: false, userId: null, email: '' })}
        confirmText="Delete"
        cancelText="Cancel"
      />

      <BasicAlertBox
        open={alert.open}
        title={alert.title}
        message={alert.message}
        type={alert.type}
        onConfirm={() => setAlert({ ...alert, open: false })}
        autoClose={alert.type === 'success'}
      />
    </DashboardLayout>
  );
};

export default UserManagement;
