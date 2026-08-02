import React, { useState } from 'react';
import { FaBars, FaSignOutAlt } from 'react-icons/fa';
import BasicAlertBox from '../BasicAlertBox';
import { logout, getUserEmail } from '../../api/auth';

const Navbar = ({ onToggleSidebar, userRole }) => {
  const [showLogoutAlert, setShowLogoutAlert] = useState(false);
  const email = getUserEmail();

  return (
    <>
      <nav className="fixed top-0 left-0 right-0 z-40 bg-white/60 backdrop-blur-xl shadow-sm border-b border-white/40">
        <div className="w-full px-4">
          <div className="flex justify-between h-16 items-center">
            <div className="flex items-center gap-3">
              <button
                onClick={onToggleSidebar}
                className="lg:hidden p-2 rounded-md hover:bg-gray-200 transition-colors text-gray-700"
              >
                <FaBars className="h-5 w-5" />
              </button>
              
            </div>

            <div className="flex items-center gap-3">
              {email && (
                <span className="text-sm text-gray-600 font-medium hidden sm:inline">
                  {email}
                </span>
              )}
              <span className="text-xs text-gray-500 bg-gray-100 px-3 py-1 rounded-full font-medium">
                {userRole}
              </span>
              <button
                onClick={() => setShowLogoutAlert(true)}
                className="flex items-center gap-2 px-3 py-2 text-sm font-medium text-red-600 hover:bg-red-50 rounded-lg transition-colors"
              >
                <FaSignOutAlt className="h-4 w-4" />
                <span className="hidden sm:inline">Logout</span>
              </button>
            </div>
          </div>
        </div>
      </nav>

      <BasicAlertBox
        open={showLogoutAlert}
        title="Confirm Logout"
        message="Are you sure you want to logout?"
        type="warning"
        onConfirm={logout}
        onCancel={() => setShowLogoutAlert(false)}
        confirmText="Logout"
        cancelText="Cancel"
      />
    </>
  );
};

export default Navbar;
