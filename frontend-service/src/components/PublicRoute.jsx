import React, { useEffect, useState } from 'react';
import { Navigate } from 'react-router-dom';
import { isAuthenticated, getUserData } from '../api/auth';

const PublicRoute = ({ children }) => {
  const [isLoading, setIsLoading] = useState(true);
  const [isAuth, setIsAuth] = useState(false);
  const [userRole, setUserRole] = useState(null);

  useEffect(() => {
    const authenticated = isAuthenticated();
    const user = getUserData();
    setIsAuth(authenticated);
    setUserRole(user?.role || null);
    setIsLoading(false);
  }, []);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-[#3da58a]"></div>
      </div>
    );
  }

  if (isAuth) {
    switch (userRole) {
      case 'ADMIN':
        return <Navigate to="/admin/users" replace />;
      case 'USER':
        return <Navigate to="/issues/new" replace />;
      default:
        return <Navigate to="/issues/new" replace />;
    }
  }

  return children;
};

export default PublicRoute;
