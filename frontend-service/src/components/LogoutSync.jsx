
import { useEffect } from 'react';

const LogoutSync = () => {
  useEffect(() => {
    const clearAuthAndRedirect = () => {
      localStorage.removeItem('authToken');
      localStorage.removeItem('userData');

      if (window.location.pathname !== '/login') {
        window.location.replace('/login');
      }
    };

    const handleStorageChange = (e) => {
      //  fires in OTHER tabs when logout key changes
      if (e.key === 'logout' && e.newValue) {
        clearAuthAndRedirect();
      }
    };

    window.addEventListener('storage', handleStorageChange);
    return () => window.removeEventListener('storage', handleStorageChange);
  }, []);

  return null;
};

export default LogoutSync;
