import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { FaArrowLeft, FaEdit, FaTrash, FaBug, FaUser, FaCalendar, FaHistory, FaArrowRight } from 'react-icons/fa';
import Tooltip from '../../components/Tooltip';
import { getIssueById, deleteIssue, updateIssueStatus, getIssueStatusHistory } from '../../api/issues';
import DashboardLayout from '../../components/layout/DashboardLayout';
import BasicAlertBox from '../../components/BasicAlertBox';
import { getUserRole } from '../../api/auth';

const IssueDetail = ({ sidebarItems, basePath = '' }) => {
  const { id } = useParams();
  const navigate = useNavigate();
  const userRole = getUserRole();
  const [issue, setIssue] = useState(null);
  const [loading, setLoading] = useState(true);
  const [deleteAlert, setDeleteAlert] = useState(false);
  const [statusAlert, setStatusAlert] = useState({ open: false, status: '' });
  const [alert, setAlert] = useState({ open: false, message: '', type: 'info', title: '' });
  const [history, setHistory] = useState([]);

  const fetchIssue = useCallback(async () => {
    try {
      setLoading(true);
      const data = await getIssueById(id);
      setIssue(data);
    } catch (error) {
      setAlert({ open: true, message: 'Failed to load issue', type: 'danger', title: 'Error' });
    } finally {
      setLoading(false);
    }
  }, [id]);

  const fetchHistory = useCallback(async () => {
    try {
      const data = await getIssueStatusHistory(id);
      setHistory(data);
    } catch (error) {
      // History may not exist yet - fail silently
    }
  }, [id]);

  useEffect(() => {
    fetchIssue();
    fetchHistory();
  }, [fetchIssue, fetchHistory]);

  const handleDelete = async () => {
    try {
      await deleteIssue(id);
      setAlert({ open: true, message: 'Issue deleted', type: 'success', title: 'Deleted' });
      setTimeout(() => navigate(`${basePath}/issues`), 1000);
    } catch (error) {
      setAlert({ open: true, message: 'Failed to delete issue', type: 'danger', title: 'Error' });
    }
    setDeleteAlert(false);
  };

  const handleStatusChange = async () => {
    try {
      const updated = await updateIssueStatus(id, statusAlert.status);
      setIssue(updated);
      await fetchHistory(); // Refresh history after status change
      setAlert({ open: true, message: `Status updated to ${statusAlert.status.replace('_', ' ')}`, type: 'success', title: 'Updated' });
    } catch (error) {
      const msg = error.response?.data?.message || 'Failed to update status';
      setAlert({ open: true, message: msg, type: 'danger', title: 'Error' });
    }
    setStatusAlert({ open: false, status: '' });
  };

  const getStatusColor = (status) => {
    const colors = {
      OPEN: 'text-blue-600 bg-blue-50 border-blue-200',
      IN_PROGRESS: 'text-yellow-600 bg-yellow-50 border-yellow-200',
      RESOLVED: 'text-green-600 bg-green-50 border-green-200',
      CLOSED: 'text-gray-600 bg-gray-50 border-gray-200',
    };
    return colors[status] || 'text-gray-600 bg-gray-50 border-gray-200';
  };

  const getStatusDot = (status) => {
    const colors = {
      OPEN: 'bg-blue-500',
      IN_PROGRESS: 'bg-yellow-500',
      RESOLVED: 'bg-green-500',
      CLOSED: 'bg-gray-500',
    };
    return colors[status] || 'bg-gray-500';
  };

  const statusDescriptions = {
    OPEN: 'Open Issue',
    IN_PROGRESS: 'In Progress Issue',
    RESOLVED: 'Resolved Issue',
    CLOSED: 'Closed Issue',
  };

  const severityDescriptions = {
    LOW: 'Low Severity',
    MEDIUM: 'Medium Severity',
    HIGH: 'High Severity',
    CRITICAL: 'Critical Severity',
  };

  const priorityDescriptions = {
    LOW: 'Low Priority  ',
    MEDIUM: 'Medium Priority',
    HIGH: 'High Priority',
    URGENT: 'Urgent Priority',
  };

  const getStatusBadge = (status) => {
    const colors = {
      OPEN: 'bg-blue-100/80 text-blue-700 border-blue-200',
      IN_PROGRESS: 'bg-yellow-100/80 text-yellow-700 border-yellow-200',
      RESOLVED: 'bg-green-100/80 text-green-700 border-green-200',
      CLOSED: 'bg-gray-100/80 text-gray-700 border-gray-200',
    };
    const title = statusDescriptions[status] || status?.replace('_', ' ');
    const badge = (
      <span aria-label={title} className={`px-3 py-1 rounded-full text-xs font-bold border backdrop-blur-sm ${colors[status] || 'bg-gray-100'}`}>
        ● {status?.replace('_', ' ')}
      </span>
    );
    return <Tooltip content={title}>{badge}</Tooltip>;
  };

  const getSeverityBadge = (severity) => {
    const colors = {
      LOW: 'bg-green-100/80 text-green-700 border-green-200',
      MEDIUM: 'bg-blue-100/80 text-blue-700 border-blue-200',
      HIGH: 'bg-orange-100/80 text-orange-700 border-orange-200',
      CRITICAL: 'bg-red-100/80 text-red-700 border-red-200',
    };
    const title = severityDescriptions[severity] || severity;
    const badge = <span aria-label={title} className={`px-3 py-1 rounded-full text-xs font-bold border backdrop-blur-sm ${colors[severity] || 'bg-gray-100'}`}>⚡ {severity}</span>;
    return <Tooltip content={title}>{badge}</Tooltip>;
  };

  const getPriorityBadge = (priority) => {
    const colors = {
      LOW: 'bg-green-100/80 text-green-700 border-green-200',
      MEDIUM: 'bg-blue-100/80 text-blue-700 border-blue-200',
      HIGH: 'bg-orange-100/80 text-orange-700 border-orange-200',
      URGENT: 'bg-red-100/80 text-red-700 border-red-200',
    };
      const title = priorityDescriptions[priority] || priority;
      const badge = <span aria-label={title} className={`px-3 py-1 rounded-full text-xs font-bold border backdrop-blur-sm ${colors[priority] || 'bg_gray-100'}`}>↑ {priority}</span>;
      return <Tooltip content={title}>{badge}</Tooltip>;
  };

  const statusTransitions = ['OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED'];

  if (loading) {
    return (
      <DashboardLayout userRole={userRole} sidebarItems={sidebarItems}>
        <div className="flex items-center justify-center h-64">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-[#3da58a]"></div>
        </div>
      </DashboardLayout>
    );
  }

  if (!issue) {
    return (
      <DashboardLayout userRole={userRole} sidebarItems={sidebarItems}>
        <div className="text-center py-20">
          <p className="text-gray-500">Issue not found</p>
          <button onClick={() => navigate(`${basePath}/issues`)} className="mt-4 text-[#1a365d] font-semibold hover:underline">← Back to Issues</button>
        </div>
      </DashboardLayout>
    );
  }

  return (
    <DashboardLayout userRole={userRole} sidebarItems={sidebarItems}>
      <div className="max-w-4xl mx-auto">
        {/* Header */}
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-6">
          <div className="flex items-center gap-3">
            <button onClick={() => navigate(`${basePath}/issues`)} className="p-2 rounded-xl bg-white/60 hover:bg-white/80 backdrop-blur-sm border border-white/40 transition-colors text-gray-600 shadow-sm">
              <FaArrowLeft />
            </button>
            <div>
              <h1 className="text-2xl font-bold text-gray-800">Issue #{issue.id}</h1>
              <p className="text-sm text-gray-500">View issue details</p>
            </div>
          </div>
          <div className="flex gap-2 mt-3 sm:mt-0">
            <button
              onClick={() => navigate(`${basePath}/issues/${issue.id}/edit`)}
              className="flex items-center gap-2 px-4 py-2 bg-[#1a365d] text-white rounded-xl text-sm font-semibold hover:bg-[#13294b] transition-all shadow-md hover:shadow-lg"
            >
              <FaEdit /> Edit
            </button>
            <button
              onClick={() => setDeleteAlert(true)}
              className="flex items-center gap-2 px-4 py-2 bg-red-500 text-white rounded-xl text-sm font-semibold hover:bg-red-600 transition-all shadow-md hover:shadow-lg"
            >
              <FaTrash /> Delete
            </button>
          </div>
        </div>

        {/* Issue Card */}
        <div className="bg-white/50 backdrop-blur-2xl rounded-2xl shadow-xl border border-white/60 overflow-hidden">
          {/* Title Bar */}
          <div className="bg-gradient-to-r from-[#1a365d] to-[#2a4a7f] p-6">
            <div className="flex items-start gap-3">
              <FaBug className="text-white/70 mt-1" size={20} />
              <div>
                <h2 className="text-xl font-bold text-white">{issue.title}</h2>
                <div className="flex flex-wrap items-center gap-2 mt-2">
                  {getStatusBadge(issue.status)}
                  {getSeverityBadge(issue.severity)}
                  {getPriorityBadge(issue.priority)}
                </div>
              </div>
            </div>
          </div>

          {/* Body */}
          <div className="p-6">
            {/* Description */}
            <div className="mb-6">
              <h3 className="text-sm font-bold text-gray-800 mb-2">Description</h3>
              <p className="text-sm text-gray-600 leading-relaxed whitespace-pre-wrap bg-white/80 p-4 rounded-xl border border-gray-100">
                {issue.description || 'No description provided.'}
              </p>
            </div>

            {/* Meta */}
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-6 bg-white/60 rounded-xl p-4 border border-gray-100">
              <div className="flex items-center gap-2 text-sm text-gray-500">
                <FaUser className="text-gray-400" />
                <span>Created by: <strong className="text-gray-700">{issue.createdBy}</strong></span>
              </div>
              <div className="flex items-center gap-2 text-sm text-gray-500">
                <FaCalendar className="text-gray-400" />
                <span>Created: <strong className="text-gray-700">{issue.createdAt ? new Date(issue.createdAt).toLocaleString() : '-'}</strong></span>
              </div>
              <div className="flex items-center gap-2 text-sm text-gray-500">
                <FaCalendar className="text-gray-400" />
                <span>Updated: <strong className="text-gray-700">{issue.updatedAt ? new Date(issue.updatedAt).toLocaleString() : '-'}</strong></span>
              </div>
            </div>

            {/* Status Transition */}
            <div className="border-t border-gray-200/50 pt-4">
              <h3 className="text-sm font-bold text-gray-800 mb-3">Update Status</h3>
              <div className="flex flex-wrap gap-2">
                {statusTransitions.map(status => (
                  <button
                    key={status}
                    onClick={() => setStatusAlert({ open: true, status })}
                    disabled={issue.status === status}
                    className={`px-4 py-2 rounded-lg text-xs font-semibold transition-all
                      ${issue.status === status
                        ? 'bg-gray-200/60 text-gray-400 cursor-not-allowed'
                        : 'bg-white/80 text-gray-700 hover:bg-[#1a365d] hover:text-white shadow-sm border border-gray-200'
                      }`}
                  >
                    {status.replace('_', ' ')}
                  </button>
                ))}
              </div>
            </div>

            {/* Status History Timeline */}
            {history.length > 0 && (
              <div className="border-t border-gray-200/50 pt-4 mt-4">
                <div className="flex items-center gap-2 mb-4">
                  <FaHistory className="text-gray-500" size={14} />
                  <h3 className="text-sm font-bold text-gray-800">Status History</h3>
                  <span className="text-xs text-gray-400 bg-gray-100 px-2 py-0.5 rounded-full">{history.length}</span>
                </div>
                <div className="relative">
                  {/* Timeline line */}
                  <div className="absolute left-[7px] top-2 bottom-2 w-0.5 bg-gray-200 rounded-full"></div>

                  <div className="space-y-4">
                    {history.map((entry, index) => (
                      <div key={entry.id} className="relative flex items-start gap-4 pl-6">
                        {/* Timeline dot */}
                        <div className={`absolute left-0 top-1.5 w-[15px] h-[15px] rounded-full border-2 border-white shadow-sm ${getStatusDot(entry.newStatus)}`}></div>

                        {/* Content */}
                        <div className={`flex-1 bg-white/70 backdrop-blur-sm rounded-xl p-3 border border-gray-100 ${index === 0 ? 'ring-1 ring-gray-200/50' : ''}`}>
                          <div className="flex flex-wrap items-center gap-2">
                                {
                                  (() => {
                                    const txt = statusDescriptions[entry.previousStatus] || entry.previousStatus?.replace('_', ' ');
                                    const inner = <span className={`px-2 py-0.5 rounded text-xs font-bold border ${getStatusColor(entry.previousStatus)}`}>{entry.previousStatus?.replace('_', ' ')}</span>;
                                    return <Tooltip content={txt}>{inner}</Tooltip>;
                                  })()
                                }
                            <FaArrowRight className="text-gray-400" size={10} />
                            {
                              (() => {
                                const txt = statusDescriptions[entry.newStatus] || entry.newStatus?.replace('_', ' ');
                                const inner = <span className={`px-2 py-0.5 rounded text-xs font-bold border ${getStatusColor(entry.newStatus)}`}>{entry.newStatus?.replace('_', ' ')}</span>;
                                return <Tooltip content={txt}>{inner}</Tooltip>;
                              })()
                            }
                          </div>
                          <div className="flex flex-wrap items-center gap-3 mt-2 text-xs text-gray-400">
                            <span className="flex items-center gap-1">
                              <FaUser size={9} />
                              {entry.changedBy}
                            </span>
                            <span className="flex items-center gap-1">
                              <FaCalendar size={9} />
                              {entry.changedAt ? new Date(entry.changedAt).toLocaleString() : '-'}
                            </span>
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Delete Confirmation */}
      <BasicAlertBox
        open={deleteAlert}
        title="Delete Issue"
        message="Are you sure you want to delete this issue? This cannot be undone."
        type="danger"
        onConfirm={handleDelete}
        onCancel={() => setDeleteAlert(false)}
        confirmText="Delete"
        cancelText="Cancel"
      />

      {/* Status Change Confirmation */}
      <BasicAlertBox
        open={statusAlert.open}
        title="Change Status"
        message={`Change issue status to "${statusAlert.status?.replace('_', ' ')}"?`}
        type="info"
        onConfirm={handleStatusChange}
        onCancel={() => setStatusAlert({ open: false, status: '' })}
        confirmText="Update"
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

export default IssueDetail;
