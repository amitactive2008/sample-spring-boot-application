export function exportToCsv(filename, rows = [], columns = []) {
  const headers = columns.map(c => c.label || c.key || '');
  const keys = columns.map(c => c.key || '');

  const escapeCell = (val) => {
    if (val === null || val === undefined) return '';
    if (val instanceof Date) return val.toLocaleString();
    if (typeof val === 'object') return JSON.stringify(val);
    const s = String(val);
    return `"${s.replace(/"/g, '""')}"`;
  };

  const lines = [];
  lines.push(headers.join(','));

  rows.forEach(row => {
    const vals = keys.map(k => {
      if (!k) return '';
      const v = row[k];
      if (k === 'createdAt' && v) return escapeCell(new Date(v));
      return escapeCell(v);
    });
    lines.push(vals.join(','));
  });

  const csvContent = lines.join('\n');
  const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
  const link = document.createElement('a');
  const url = URL.createObjectURL(blob);
  link.setAttribute('href', url);
  link.setAttribute('download', filename);
  link.style.visibility = 'hidden';
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}

export default exportToCsv;
