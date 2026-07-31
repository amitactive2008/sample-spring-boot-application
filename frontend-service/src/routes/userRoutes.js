import React from 'react';
import { FaPlusCircle, FaList } from 'react-icons/fa';

import IssueList from '../pages/issues/IssueList';
import CreateIssue from '../pages/issues/CreateIssue';
import IssueDetail from '../pages/issues/IssueDetail';
import EditIssue from '../pages/issues/EditIssue';

const sidebarItems = [
  {
    section: 'Issues',
    items: [
      { name: 'Create Issue', path: '/issues/new', icon: <FaPlusCircle size={16} /> },
      { name: 'All Issues', path: '/issues', icon: <FaList size={16} /> },
    ],
  },
];

export const userRoutes = [
  { path: '/issues', element: <IssueList sidebarItems={sidebarItems} basePath="" /> },
  { path: '/issues/new', element: <CreateIssue sidebarItems={sidebarItems} basePath="" /> },
  { path: '/issues/:id', element: <IssueDetail sidebarItems={sidebarItems} basePath="" /> },
  { path: '/issues/:id/edit', element: <EditIssue sidebarItems={sidebarItems} basePath="" /> },
];
