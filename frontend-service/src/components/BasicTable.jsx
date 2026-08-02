import React, { useState } from 'react';
import { FaSort, FaSortUp, FaSortDown } from 'react-icons/fa';

const BasicTable = ({
  columns,
  data,
  actions,
  className = '',
  page: controlledPage,
  rowsPerPage: controlledRowsPerPage,
  totalCount = null,
  onPageChange,
  onRowsPerPageChange,
  onSort,
  sortConfig,
  loading = false,
  emptyMessage = 'No data available',
}) => {
  const [internalRowsPerPage, setInternalRowsPerPage] = useState(controlledRowsPerPage || 10);
  const [internalPage, setInternalPage] = useState(controlledPage || 1);

  const rowsPerPage = controlledRowsPerPage !== undefined ? controlledRowsPerPage : internalRowsPerPage;
  const page = controlledPage !== undefined ? controlledPage : internalPage;

  const totalRows = totalCount !== null ? totalCount : data.length;
  const from = totalRows === 0 ? 0 : (page - 1) * rowsPerPage + 1;
  const to = Math.min(page * rowsPerPage, totalRows);
  const totalPages = Math.ceil(totalRows / rowsPerPage);

  const pagedData = totalCount !== null ? data : data.slice((page - 1) * rowsPerPage, page * rowsPerPage);

  const handleRowsPerPageChange = (newRows) => {
    if (onRowsPerPageChange) onRowsPerPageChange(newRows);
    else setInternalRowsPerPage(newRows);
    if (onPageChange) onPageChange(1);
    else setInternalPage(1);
  };

  const handlePageChange = (newPage) => {
    if (onPageChange) onPageChange(newPage);
    else setInternalPage(newPage);
  };

  const renderSortIndicator = (columnKey) => {
    if (!sortConfig || sortConfig.key !== columnKey) {
      return <FaSort className="w-3 h-3 text-gray-400" />;
    }
    return sortConfig.direction === 'asc'
      ? <FaSortUp className="w-3 h-3 text-blue-600" />
      : <FaSortDown className="w-3 h-3 text-blue-600" />;
  };

  return (
    <div className="w-full max-w-full py-2">
      <div className={`overflow-x-auto rounded-2xl shadow-xl border border-white/40 bg-white/30 backdrop-blur-xl ${className}`}>
        <table className="w-full min-w-[600px] text-left font-['Inter',sans-serif] text-[13px]">
          <thead>
            <tr className="bg-[#a4a9fc] text-[#1a1a2e]">
              {columns.map(col => (
                <th
                  key={col.key}
                  className={`p-4 font-semibold text-[14px] tracking-wide border-b border-[#d1d5db] ${col.sortable ? 'cursor-pointer hover:bg-[#8b8ffc] transition-colors' : ''}`}
                  onClick={() => col.sortable && onSort && onSort(col.key)}
                >
                  <div className="flex items-center gap-2">
                    <span>{col.label}</span>
                    {col.sortable && renderSortIndicator(col.key)}
                  </div>
                </th>
              ))}
              {actions && <th className="p-4 font-semibold text-[14px] border-b border-[#d1d5db]">Action</th>}
            </tr>
          </thead>
          <tbody className="bg-white/60 text-[13px]">
            {loading ? (
              <tr>
                <td colSpan={columns.length + (actions ? 1 : 0)} className="p-6 text-center text-gray-500 font-semibold">
                  <div className="flex items-center justify-center gap-2">
                    <div className="animate-spin rounded-full h-5 w-5 border-b-2 border-[#a4a9fc]"></div>
                    Loading...
                  </div>
                </td>
              </tr>
            ) : pagedData.length === 0 ? (
              <tr>
                <td colSpan={columns.length + (actions ? 1 : 0)} className="p-6 text-center text-gray-500 font-semibold">{emptyMessage}</td>
              </tr>
            ) : (
              pagedData.map((row, idx) => (
                <tr
                  key={row.id || idx}
                  className={`transition-colors ${idx % 2 === 0 ? 'bg-white/60' : 'bg-white/40'} hover:bg-white/80`}
                >
                  {columns.map(col => (
                    <td key={col.key} className="p-4 align-middle text-[#22223b] border-b border-[#f0f1f6]">
                      {col.render ? col.render(row, idx) : row[col.key]}
                    </td>
                  ))}
                  {actions && (
                    <td className="p-4 align-middle border-b border-[#f0f1f6]">{actions(row)}</td>
                  )}
                </tr>
              ))
            )}
          </tbody>
        </table>

        {/* Pagination */}
        <div className="flex flex-col sm:flex-row sm:items-center justify-between bg-[#a4a9fc] px-6 py-3 rounded-b-2xl text-[14px] font-semibold border-t border-[#d1d5db]">
          <div className="flex items-center gap-2 mb-2 sm:mb-0">
            <span className="font-bold">Rows Per Page</span>
            <select
              className="border border-gray-300 rounded px-2 py-1 bg-white text-sm focus:outline-none"
              value={rowsPerPage}
              onChange={e => handleRowsPerPageChange(Number(e.target.value))}
            >
              {[5, 10, 25, 50].map(n => (
                <option key={n} value={n}>{n}</option>
              ))}
            </select>
          </div>
          <div className="flex items-center gap-2">
            <span>{from}-{to} of {totalRows}</span>
            <button
              className="px-2 py-1 rounded disabled:opacity-50 hover:bg-[#8b8ffc] transition-colors"
              onClick={() => handlePageChange(page - 1)}
              disabled={page <= 1}
            >
              &#60;
            </button>
            <button
              className="px-2 py-1 rounded disabled:opacity-50 hover:bg-[#8b8ffc] transition-colors"
              onClick={() => handlePageChange(page + 1)}
              disabled={page >= totalPages}
            >
              &#62;
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default BasicTable;
