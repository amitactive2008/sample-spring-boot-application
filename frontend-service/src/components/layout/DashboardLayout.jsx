import React from 'react';
import Navbar from './Navbar';
import Sidebar from './Sidebar';
import { useSidebar } from './SidebarContext';

const DashboardLayout = ({ children, userRole, sidebarItems }) => {
  const { isSidebarOpen, isMobile, toggleSidebar, setSidebarOpen } = useSidebar();

  return (
    <div className="min-h-screen bg-gradient-to-br from-gray-50 via-white to-gray-100 relative overflow-hidden">
      {/* Decorative blurred circles */}
      <div className="fixed -top-[20%] -left-[10%] w-[60vw] h-[60vw] max-w-[900px] max-h-[900px] min-w-[400px] min-h-[400px] bg-[#3da58a]/30 rounded-full blur-[150px] pointer-events-none" />
      <div className="fixed -bottom-[20%] -right-[10%] w-[55vw] h-[55vw] max-w-[850px] max-h-[850px] min-w-[350px] min-h-[350px] bg-[#1a365d]/25 rounded-full blur-[140px] pointer-events-none" />
      <div className="fixed top-[20%] -right-[5%] w-[45vw] h-[45vw] max-w-[700px] max-h-[700px] min-w-[300px] min-h-[300px] bg-[#6366f1]/20 rounded-full blur-[130px] pointer-events-none" />
      <div className="fixed bottom-[10%] left-[5%] w-[40vw] h-[40vw] max-w-[650px] max-h-[650px] min-w-[250px] min-h-[250px] bg-[#f59e0b]/15 rounded-full blur-[120px] pointer-events-none" />

      <Navbar
        userRole={userRole}
        onToggleSidebar={toggleSidebar}
      />
      <Sidebar
        items={sidebarItems}
        onToggle={setSidebarOpen}
        isMobile={isMobile}
        isOpen={isSidebarOpen}
      />
      <main className={`pt-16 transition-all duration-300 ${
        isMobile
          ? 'pl-0'
          : isSidebarOpen
            ? 'pl-64'
            : 'pl-16'
      }`}>
        <div className="p-4 lg:p-6">
          {children}
        </div>
      </main>
    </div>
  );
};

export default DashboardLayout;
