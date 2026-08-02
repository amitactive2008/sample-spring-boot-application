import React, { createContext, useContext, useState, useEffect } from 'react';

const SidebarContext = createContext();

export const useSidebar = () => {
  const context = useContext(SidebarContext);
  if (!context) {
    throw new Error('useSidebar must be used within a SidebarProvider');
  }
  return context;
};

export const SidebarProvider = ({ children }) => {
  const [isSidebarOpen, setIsSidebarOpen] = useState(true);
  const [isMobile, setIsMobile] = useState(false);
  const [isInitialized, setIsInitialized] = useState(false);

  useEffect(() => {
    const checkMobile = () => {
      const mobile = window.innerWidth < 1024;
      setIsMobile(mobile);
      if (!isInitialized) {
        setIsSidebarOpen(!mobile);
        setIsInitialized(true);
      }
    };
    checkMobile();
    window.addEventListener('resize', checkMobile);
    return () => window.removeEventListener('resize', checkMobile);
  }, [isInitialized]);

  const toggleSidebar = () => setIsSidebarOpen(!isSidebarOpen);
  const setSidebarOpen = (open) => setIsSidebarOpen(open);

  return (
    <SidebarContext.Provider value={{ isSidebarOpen, isMobile, toggleSidebar, setSidebarOpen }}>
      {children}
    </SidebarContext.Provider>
  );
};
