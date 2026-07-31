import React, { useState } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { FaBars, FaTimes, FaBug, FaChevronDown, FaChevronRight } from 'react-icons/fa';

const Sidebar = ({ items, onToggle, isMobile, isOpen: externalIsOpen }) => {
  const navigate = useNavigate();
  const location = useLocation();
  const [collapsedSections, setCollapsedSections] = useState({});

  const isOpen = externalIsOpen !== undefined ? externalIsOpen : true;

  const toggleSidebar = () => {
    onToggle(!isOpen);
  };

  const toggleSection = (sectionName) => {
    setCollapsedSections(prev => ({ ...prev, [sectionName]: !prev[sectionName] }));
  };

  return (
    <>
      {/* Mobile Overlay */}
      {isMobile && isOpen && (
        <div
          className="fixed inset-0 bg-black/30 backdrop-blur-[1px] z-40 lg:hidden"
          onClick={toggleSidebar}
        />
      )}

      {/* Sidebar */}
      <aside
        className={`fixed top-0 left-0 h-screen bg-white/60 backdrop-blur-xl border-r border-white/40 shadow-2xl transition-all duration-300 ease-in-out z-50
          ${isOpen ? 'w-64' : 'w-16'}
          ${isMobile && !isOpen ? '-translate-x-full' : 'translate-x-0'}
          ${isMobile ? 'w-64' : ''}`}
      >
        <div className="h-full overflow-y-auto sidebar-scroll">
          {/* Header */}
          <div className="h-16 flex items-center px-4 border-b border-white/40 bg-white/40 gap-3">
            <button
              onClick={toggleSidebar}
              className="p-2 rounded-lg hover:bg-gray-100 transition-all text-gray-600"
            >
              {isOpen ? <FaTimes className="h-5 w-5" /> : <FaBars className="h-5 w-5" />}
            </button>
            {isOpen && (
              <div className="flex items-center gap-2">
                <span className="w-8 h-8 rounded-lg bg-[#3da58a] flex items-center justify-center shadow-sm">
                  <FaBug className="h-4 w-4 text-white" />
                </span>
                <span className="text-gray-900 font-bold text-sm">Issue Tracker</span>
              </div>
            )}
          </div>

          {/* Menu Items */}
          <nav className="p-3 space-y-1">
            {items.map((section, sIdx) => (
              <div key={sIdx} className="mb-2">
                {/* Section Header */}
                {section.section && isOpen && (
                  <button
                    onClick={() => toggleSection(section.section)}
                    className="w-full flex items-center justify-between px-3 py-2 text-xs font-bold text-gray-400 uppercase tracking-wider hover:text-gray-600 transition-colors"
                  >
                    <span>{section.section}</span>
                    {collapsedSections[section.section] ? <FaChevronRight size={10} /> : <FaChevronDown size={10} />}
                  </button>
                )}

                {/* Section Items */}
                {!collapsedSections[section.section] && section.items.map((item, iIdx) => {
                  const isActive = location.pathname === item.path;
                  return (
                    <button
                      key={iIdx}
                      onClick={() => {
                        navigate(item.path);
                        if (isMobile) onToggle(false);
                      }}
                      className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium transition-all duration-200
                        ${isActive
                          ? 'bg-gradient-to-r from-[#1a365d] to-[#2a4a7f] text-white shadow-md'
                          : 'text-gray-600 hover:bg-gray-100 hover:text-gray-900'
                        }
                        ${!isOpen && !isMobile ? 'justify-center' : ''}`}
                      title={!isOpen ? item.name : ''}
                    >
                      <span className={`flex-shrink-0 ${isActive ? 'text-white' : 'text-gray-400'}`}>
                        {item.icon}
                      </span>
                      {(isOpen || isMobile) && <span>{item.name}</span>}
                    </button>
                  );
                })}
              </div>
            ))}
          </nav>
        </div>
      </aside>
    </>
  );
};

export default Sidebar;
