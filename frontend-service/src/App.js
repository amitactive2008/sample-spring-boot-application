import React from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { authRoutes, userRoutes, adminRoutes } from './routes';
import AuthGuard from './components/AuthGuard';
import PublicRoute from './components/PublicRoute';
import LogoutSync from './components/LogoutSync';
import { SidebarProvider } from './components/layout/SidebarContext';

function App() {
  return (
    <BrowserRouter>
      <LogoutSync />
      <Routes>
        {/* Public Auth Routes */}
        {authRoutes.map((route, index) => (
          <Route
            key={`auth-${index}`}
            path={route.path}
            element={<PublicRoute>{route.element}</PublicRoute>}
          />
        ))}

        {/* User Routes — Protected (USER role) */}
        {userRoutes.map((route, index) => (
          <Route
            key={`user-${index}`}
            path={route.path}
            element={
              <AuthGuard requiredRole="USER">
                <SidebarProvider>
                  {route.element}
                </SidebarProvider>
              </AuthGuard>
            }
          />
        ))}

        {/* Admin Routes — Protected (ADMIN role) */}
        {adminRoutes.map((route, index) => (
          <Route
            key={`admin-${index}`}
            path={route.path}
            element={
              <AuthGuard requiredRole="ADMIN">
                <SidebarProvider>
                  {route.element}
                </SidebarProvider>
              </AuthGuard>
            }
          />
        ))}

        {/* Default redirect */}
        <Route path="/" element={<Navigate to="/login" replace />} />
        <Route path="*" element={<Navigate to="/login" replace />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
