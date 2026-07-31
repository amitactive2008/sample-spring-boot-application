import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import * as Yup from 'yup';
import BasicForm from '../../components/BasicForm';
import CustomSelectField from '../../components/CustomSelectField';
import CustomButton from '../../components/CustomButton';
import BasicAlertBox from '../../components/BasicAlertBox';
import DashboardLayout from '../../components/layout/DashboardLayout';
import { getIssueById, updateIssue } from '../../api/issues';
import { getUserRole } from '../../api/auth';
import { FaArrowLeft } from 'react-icons/fa';

const issueSchema = Yup.object().shape({
  title: Yup.string().required('Title is required'),
  description: Yup.string(),
  severity: Yup.string().required('Severity is required'),
  priority: Yup.string().required('Priority is required'),
});

const severityOptions = [
  { value: 'LOW', label: 'Low' },
  { value: 'MEDIUM', label: 'Medium' },
  { value: 'HIGH', label: 'High' },
  { value: 'CRITICAL', label: 'Critical' },
];

const priorityOptions = [
  { value: 'LOW', label: 'Low' },
  { value: 'MEDIUM', label: 'Medium' },
  { value: 'HIGH', label: 'High' },
  { value: 'URGENT', label: 'Urgent' },
];

const EditIssue = ({ sidebarItems, basePath = '' }) => {
  const { id } = useParams();
  const navigate = useNavigate();
  const userRole = getUserRole();
  const [issue, setIssue] = useState(null);
  const [loading, setLoading] = useState(true);
  const [alert, setAlert] = useState({ open: false, message: '', type: 'info', title: '' });

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

  useEffect(() => {
    fetchIssue();
  }, [fetchIssue]);

  const handleSubmit = async (values, { setSubmitting }) => {
    try {
      await updateIssue(id, {
        title: values.title,
        description: values.description,
        severity: values.severity,
        priority: values.priority,
      });
      setAlert({ open: true, message: 'Issue updated successfully!', type: 'success', title: 'Updated' });
      setTimeout(() => navigate(`${basePath}/issues/${id}`), 1200);
    } catch (error) {
      const msg = error.response?.data?.message || error.response?.data?.error || 'Failed to update issue';
      setAlert({ open: true, message: msg, type: 'danger', title: 'Error' });
    } finally {
      setSubmitting(false);
    }
  };

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
        </div>
      </DashboardLayout>
    );
  }

  return (
    <DashboardLayout userRole={userRole} sidebarItems={sidebarItems}>
      <div className="max-w-2xl mx-auto">
        {/* Header */}
        <div className="flex items-center gap-3 mb-6">
          <button onClick={() => navigate(-1)} className="p-2 rounded-lg hover:bg-gray-200 transition-colors text-gray-600">
            <FaArrowLeft />
          </button>
          <div>
            <h1 className="text-2xl font-bold text-gray-800">Edit Issue #{id}</h1>
            <p className="text-sm text-gray-500">Update issue details</p>
          </div>
        </div>

        {/* Form */}
        <div className="bg-white/30 backdrop-blur-xl rounded-2xl shadow-xl p-6 border border-white/40">
          <BasicForm
            initialValues={{
              title: issue.title || '',
              description: issue.description || '',
              severity: issue.severity || 'MEDIUM',
              priority: issue.priority || 'MEDIUM',
            }}
            validationSchema={issueSchema}
            onSubmit={handleSubmit}
            enableReinitialize={true}
          >
            {({ errors, touched, handleChange, values, isSubmitting }) => (
              <>
                <div className="flex flex-col mb-2">
                  <label className="text-xs font-medium text-gray-700 mb-1">Issue Title</label>
                  <input
                    name="title"
                    value={values.title}
                    onChange={handleChange}
                    className="bg-white border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400 focus:border-transparent"
                    placeholder="Enter issue title..."
                  />
                  {errors.title && touched.title && (
                    <span className="text-red-500 text-xs mt-1">{errors.title}</span>
                  )}
                </div>
                <div className="flex flex-col mb-2">
                  <label className="text-xs font-medium text-gray-700 mb-1">Description</label>
                  <textarea
                    name="description"
                    value={values.description}
                    onChange={handleChange}
                    rows={5}
                    className="bg-white border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400 focus:border-transparent resize-y"
                    placeholder="Describe the issue in detail..."
                  />
                </div>
                <div className="grid grid-cols-2 gap-4">
                  <CustomSelectField
                    name="severity"
                    label="Severity"
                    value={values.severity}
                    onChange={handleChange}
                    options={severityOptions}
                    error={errors.severity}
                    touched={touched.severity}
                  />
                  <CustomSelectField
                    name="priority"
                    label="Priority"
                    value={values.priority}
                    onChange={handleChange}
                    options={priorityOptions}
                    error={errors.priority}
                    touched={touched.priority}
                  />
                </div>
                <div className="flex gap-3">
                  <CustomButton type="submit" disabled={isSubmitting}>
                    {isSubmitting ? 'Saving...' : 'Save Changes'}
                  </CustomButton>
                  <button
                    type="button"
                    onClick={() => navigate(-1)}
                    className="w-full py-2.5 px-4 bg-gray-200 text-gray-700 text-xs font-bold rounded-lg mt-4 mb-2 hover:bg-gray-300 transition-all"
                  >
                    Cancel
                  </button>
                </div>
              </>
            )}
          </BasicForm>
        </div>
      </div>

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

export default EditIssue;
