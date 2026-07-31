import React, { useEffect, useState } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { isAuthenticated, getUserData } from '../api/auth';

const AuthGuard = ({ children, requiredRole = null }) => {
  const [isLoading, setIsLoading] = useState(true);
  const [isAuth, setIsAuth] = useState(false);
  const [userRole, setUserRole] = useState(null);
  const location = useLocation();

  useEffect(() => {
    const authenticated = isAuthenticated();
    const user = getUserData();
    setIsAuth(authenticated);
    setUserRole(user?.role || null);
    setIsLoading(false);
  }, [location.pathname]);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-[#3da58a]"></div>
      </div>
    );
  }

  if (!isAuth) {
    return <Navigate to="/login" replace />;
  }

  if (requiredRole && userRole !== requiredRole) {
    switch (userRole) {
      case 'ADMIN':
        return <Navigate to="/admin/users" replace />;
      case 'USER':
        return <Navigate to="/issues/new" replace />;
      default:
        return <Navigate to="/login" replace />;
    }
  }

  return children;
};

export default AuthGuard;
