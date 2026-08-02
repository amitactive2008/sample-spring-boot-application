import React, { useState, useEffect, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { FaPlus, FaEye, FaEdit, FaTrash, FaSearch, FaDownload } from 'react-icons/fa';
import { getIssues, deleteIssue, getIssueCountByStatus } from '../../api/issues';
import DashboardLayout from '../../components/layout/DashboardLayout';
import BasicTable from '../../components/BasicTable';
import BasicAlertBox from '../../components/BasicAlertBox';
import CustomButton2 from '../../components/CustomButton2';
import { getUserRole } from '../../api/auth';
import Tooltip from '../../components/Tooltip';
import { exportToCsv } from '../../utils/csv';

const IssueList = ({ sidebarItems, basePath = '' }) => {
  const navigate = useNavigate();
  const userRole = getUserRole();
  const [issues, setIssues] = useState([]);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(1);
  const [rowsPerPage, setRowsPerPage] = useState(10);
  const [totalCount, setTotalCount] = useState(0);
  const [sortConfig, setSortConfig] = useState({ key: 'createdAt', direction: 'desc' });
  const [filters, setFilters] = useState({ title: '', status: '', priority: '' });
  const [deleteAlert, setDeleteAlert] = useState({ open: false, issueId: null });
  const [alert, setAlert] = useState({ open: false, message: '', type: 'info', title: '' });
  const [statusCounts, setStatusCounts] = useState({ TOTAL: 0, OPEN: 0, IN_PROGRESS: 0, RESOLVED: 0, CLOSED: 0 });

  const fetchIssues = useCallback(async () => {
    try {
      setLoading(true);
      const params = {
        page: page - 1,
        size: rowsPerPage,
        sort: `${sortConfig.key},${sortConfig.direction}`,
      };
      if (filters.title) params.title = filters.title;
      if (filters.status) params.status = filters.status;
      if (filters.priority) params.priority = filters.priority;

      const response = await getIssues(params);
      setIssues(response.content || []);
      setTotalCount(response.totalElements || 0);
    } catch (error) {
      console.error('Failed to fetch issues:', error);
    } finally {
      setLoading(false);
    }
  }, [page, rowsPerPage, sortConfig, filters]);

  const fetchStatusCounts = useCallback(async () => {
    try {
      const countsResp = await getIssueCountByStatus();
      // Debug log to inspect backend response shape
      // eslint-disable-next-line no-console
      console.debug('getIssueCountByStatus response:', countsResp);

      // Backend may return an envelope like { total, countByStatus: { OPEN: 1, ... } }
      let map = countsResp;
      let totalFromResp = 0;
      if (countsResp && typeof countsResp === 'object' && countsResp.countByStatus) {
        map = countsResp.countByStatus;
        totalFromResp = Number(countsResp.total ?? countsResp.totalElements ?? 0) || 0;
      }

      const counts = { TOTAL: 0, OPEN: 0, IN_PROGRESS: 0, RESOLVED: 0, CLOSED: 0 };

      if (Array.isArray(map)) {
        map.forEach(item => {
          if (!item) return;
          const key = item.status || item.key || item.name || item.label;
          const value = item.count ?? item.value ?? item.countValue ?? item.qty ?? 0;
          const normKey = String(key || '').toUpperCase();
          if (counts.hasOwnProperty(normKey)) counts[normKey] = Number(value) || 0;
        });
      } else if (map && typeof map === 'object') {
        // normalize object keys
        counts.OPEN = Number(map.OPEN ?? map.open ?? map['Open'] ?? map['open'] ?? 0) || 0;
        counts.IN_PROGRESS = Number(map.IN_PROGRESS ?? map['IN_PROGRESS'] ?? map.inProgress ?? map['in_progress'] ?? map['In Progress'] ?? 0) || 0;
        counts.RESOLVED = Number(map.RESOLVED ?? map.resolved ?? map['Resolved'] ?? 0) || 0;
        counts.CLOSED = Number(map.CLOSED ?? map.closed ?? map['Closed'] ?? 0) || 0;
      }

      // prefer explicit total from response, otherwise sum values
      counts.TOTAL = totalFromResp || (counts.OPEN + counts.IN_PROGRESS + counts.RESOLVED + counts.CLOSED);

      setStatusCounts(counts);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error('Failed to fetch issue counts:', err);
    }
  }, []);

  useEffect(() => {
    fetchIssues();
    fetchStatusCounts();
  }, [fetchIssues, fetchStatusCounts]);

  const handleSort = (key) => {
    setSortConfig(prev => ({
      key,
      direction: prev.key === key && prev.direction === 'asc' ? 'desc' : 'asc',
    }));
    setPage(1);
  };

  const handleDelete = async () => {
    try {
      await deleteIssue(deleteAlert.issueId);
      setDeleteAlert({ open: false, issueId: null });
      setAlert({ open: true, message: 'Issue deleted successfully', type: 'success', title: 'Deleted' });
      fetchIssues();
    } catch (error) {
      setAlert({ open: true, message: 'Failed to delete issue', type: 'danger', title: 'Error' });
    }
  };

  const getStatusBadge = (status) => {
    const colors = {
      OPEN: 'bg-blue-100 text-blue-700',
      IN_PROGRESS: 'bg-yellow-100 text-yellow-700',
      RESOLVED: 'bg-green-100 text-green-700',
      CLOSED: 'bg-gray-100 text-gray-700',
    };
    return (
      <span className={`px-2 py-0.5 rounded-full text-xs font-semibold ${colors[status] || 'bg-gray-100'}`}>
        {status?.replace('_', ' ')}
      </span>
    );
  };

  const getSeverityBadge = (severity) => {
    const colors = {
      LOW: 'bg-green-100 text-green-700',
      MEDIUM: 'bg-blue-100 text-blue-700',
      HIGH: 'bg-orange-100 text-orange-700',
      CRITICAL: 'bg-red-100 text-red-700',
    };
    return (
      <span className={`px-2 py-0.5 rounded-full text-xs font-semibold ${colors[severity] || 'bg-gray-100'}`}>
        {severity}
      </span>
    );
  };

  const getPriorityBadge = (priority) => {
    const colors = {
      LOW: 'bg-green-100 text-green-700',
      MEDIUM: 'bg-blue-100 text-blue-700',
      HIGH: 'bg-orange-100 text-orange-700',
      URGENT: 'bg-red-100 text-red-700',
    };
    return (
      <span className={`px-2 py-0.5 rounded-full text-xs font-semibold ${colors[priority] || 'bg-gray-100'}`}>
        {priority}
      </span>
    );
  };

  const columns = [
    { key: 'id', label: 'ID', sortable: true },
    { key: 'title', label: 'Title', sortable: true, render: (row) => (
      <span className="font-medium text-gray-800 max-w-[200px] truncate block">{row.title}</span>
    )},
    { key: 'status', label: 'Status', sortable: true, render: (row) => getStatusBadge(row.status) },
    { key: 'severity', label: 'Severity', sortable: true, render: (row) => getSeverityBadge(row.severity) },
    { key: 'priority', label: 'Priority', sortable: true, render: (row) => getPriorityBadge(row.priority) },
    { key: 'createdBy', label: 'Created By', sortable: true },
    { key: 'createdAt', label: 'Created', sortable: true, render: (row) => (
      <span className="text-xs text-gray-500">{row.createdAt ? new Date(row.createdAt).toLocaleDateString() : '-'}</span>
    )},
  ];

  return (
    <DashboardLayout userRole={userRole} sidebarItems={sidebarItems}>
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-4">
        <h1 className="text-2xl font-bold text-gray-800">Issues</h1>
          <div className="flex items-center gap-2 mt-2 sm:mt-0">
          <button
            onClick={() => exportToCsv('issues.csv', issues, columns)}
            className="flex items-center gap-2 px-3 py-2 bg-white text-gray-700 rounded-lg text-sm font-semibold border border-gray-200 hover:bg-gray-50 transition-colors shadow-sm"
          >
            <FaDownload /> Export CSV
          </button>
          <button
            onClick={() => navigate(`${basePath}/issues/new`)}
            className="flex items-center gap-2 px-4 py-2 bg-[#3da58a] text-white rounded-lg text-sm font-semibold hover:bg-[#2d8a72] transition-colors shadow-md"
          >
            <FaPlus /> New Issue
          </button>
        </div>
      </div>

        {/* Status summary cards */}
        <div className="grid grid-cols-1 sm:grid-cols-5 gap-3 mb-4">
          <div className="bg-white/30 backdrop-blur-xl rounded-2xl shadow p-4 border border-white/40 flex items-center justify-between">
            <div>
              <div className="text-sm text-gray-500">Total</div>
              <div className="text-2xl font-bold text-gray-800">{statusCounts.TOTAL ?? 0}</div>
            </div>
          </div>
          <div className="bg-white/30 backdrop-blur-xl rounded-2xl shadow p-4 border border-white/40 flex items-center justify-between">
            <div>
              <div className="text-sm text-gray-500">Open</div>
              <div className="text-2xl font-bold text-gray-800">{statusCounts.OPEN ?? 0}</div>
            </div>
          </div>
          <div className="bg-white/30 backdrop-blur-xl rounded-2xl shadow p-4 border border-white/40 flex items-center justify-between">
            <div>
              <div className="text-sm text-gray-500">In Progress</div>
              <div className="text-2xl font-bold text-gray-800">{statusCounts.IN_PROGRESS ?? 0}</div>
            </div>
          </div>
          <div className="bg-white/30 backdrop-blur-xl rounded-2xl shadow p-4 border border-white/40 flex items-center justify-between">
            <div>
              <div className="text-sm text-gray-500">Resolved</div>
              <div className="text-2xl font-bold text-gray-800">{statusCounts.RESOLVED ?? 0}</div>
            </div>
          </div>
          <div className="bg-white/30 backdrop-blur-xl rounded-2xl shadow p-4 border border-white/40 flex items-center justify-between">
            <div>
              <div className="text-sm text-gray-500">Closed</div>
              <div className="text-2xl font-bold text-gray-800">{statusCounts.CLOSED ?? 0}</div>
            </div>
          </div>
        </div>

      {/* Filters */}
      <div className="bg-white/30 backdrop-blur-xl rounded-2xl shadow-xl p-4 mb-4 border border-white/40">
        <div className="grid grid-cols-1 sm:grid-cols-4 gap-3">
          <div className="relative">
            <FaSearch className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" size={12} />
            <input
              type="text"
              placeholder="Search by title..."
              value={filters.title}
              onChange={(e) => { setFilters(f => ({ ...f, title: e.target.value })); setPage(1); }}
              className="w-full pl-8 pr-3 py-2 bg-white border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-[#a4a9fc] focus:border-transparent"
            />
          </div>
          <select
            value={filters.status}
            onChange={(e) => { setFilters(f => ({ ...f, status: e.target.value })); setPage(1); }}
            className="bg-white border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-[#a4a9fc] focus:border-transparent"
          >
            <option value="">All Status</option>
            <option value="OPEN">Open</option>
            <option value="IN_PROGRESS">In Progress</option>
            <option value="RESOLVED">Resolved</option>
            <option value="CLOSED">Closed</option>
          </select>
          <select
            value={filters.priority}
            onChange={(e) => { setFilters(f => ({ ...f, priority: e.target.value })); setPage(1); }}
            className="bg-white border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-[#a4a9fc] focus:border-transparent"
          >
            <option value="">All Priority</option>
            <option value="LOW">Low</option>
            <option value="MEDIUM">Medium</option>
            <option value="HIGH">High</option>
            <option value="URGENT">Urgent</option>
          </select>
          <button
            onClick={() => { setFilters({ title: '', status: '', priority: '' }); setPage(1); }}
            className="px-3 py-2 text-sm font-medium text-gray-600 bg-gray-100 rounded-lg hover:bg-gray-200 transition-colors"
          >
            Clear Filters
          </button>
        </div>
      </div>

      {/* Table */}
      <BasicTable
        columns={columns}
        data={issues}
        loading={loading}
        page={page}
        rowsPerPage={rowsPerPage}
        totalCount={totalCount}
        onPageChange={setPage}
        onRowsPerPageChange={(n) => { setRowsPerPage(n); setPage(1); }}
        onSort={handleSort}
        sortConfig={sortConfig}
        emptyMessage="No issues found"
        actions={(row) => (
          <div className="flex items-center gap-1">
            <Tooltip content="View">
              <CustomButton2 color="blue" className="!py-1 !px-2 !text-xs" onClick={() => navigate(`${basePath}/issues/${row.id}`)}>
                <FaEye />
              </CustomButton2>
            </Tooltip>
            <Tooltip content="Edit">
              <CustomButton2 color="mint" className="!py-1 !px-2 !text-xs" onClick={() => navigate(`${basePath}/issues/${row.id}/edit`)}>
                <FaEdit />
              </CustomButton2>
            </Tooltip>
            <Tooltip content="Delete">
              <CustomButton2 color="danger" className="!py-1 !px-2 !text-xs" onClick={() => setDeleteAlert({ open: true, issueId: row.id })}>
                <FaTrash />
              </CustomButton2>
            </Tooltip>
          </div>
        )}
      />

      <BasicAlertBox
        open={deleteAlert.open}
        title="Delete Issue"
        message="Are you sure you want to delete this issue? This action cannot be undone."
        type="danger"
        onConfirm={handleDelete}
        onCancel={() => setDeleteAlert({ open: false, issueId: null })}
        confirmText="Delete"
        cancelText="Cancel"
      />

      <BasicAlertBox
        open={alert.open}
        title={alert.title}
        message={alert.message}
        type={alert.type}
        onConfirm={() => setAlert({ ...alert, open: false })}
        autoClose={true}
      />
    </DashboardLayout>
  );
};

export default IssueList;
