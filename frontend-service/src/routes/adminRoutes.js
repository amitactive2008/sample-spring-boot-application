import React from 'react';
import { FaPlusCircle, FaList, FaUsers } from 'react-icons/fa';

import IssueList from '../pages/issues/IssueList';
import CreateIssue from '../pages/issues/CreateIssue';
import IssueDetail from '../pages/issues/IssueDetail';
import EditIssue from '../pages/issues/EditIssue';
import UserManagement from '../pages/users/UserManagement';

const sidebarItems = [

{
    section: 'Administration',
    items: [
      { name: 'Users', path: '/admin/users', icon: <FaUsers size={16} /> },
    ],
  },

  {
    section: 'Issues',
    items: [
      { name: 'Create Issue', path: '/admin/issues/new', icon: <FaPlusCircle size={16} /> },
      { name: 'All Issues', path: '/admin/issues', icon: <FaList size={16} /> },
    ],
  },
  
];

export const adminRoutes = [
  { path: '/admin/issues', element: <IssueList sidebarItems={sidebarItems} basePath="/admin" /> },
  { path: '/admin/issues/new', element: <CreateIssue sidebarItems={sidebarItems} basePath="/admin" /> },
  { path: '/admin/issues/:id', element: <IssueDetail sidebarItems={sidebarItems} basePath="/admin" /> },
  { path: '/admin/issues/:id/edit', element: <EditIssue sidebarItems={sidebarItems} basePath="/admin" /> },
  { path: '/admin/users', element: <UserManagement sidebarItems={sidebarItems} /> },
];
