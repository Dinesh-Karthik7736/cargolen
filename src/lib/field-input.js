const NUMERIC_FIELDS = new Set(['gross', 'net', 'total', 'invoiceGross', 'packingGross', 'blGross', 'qty', 'unit']);
const INTEGER_FIELDS = new Set(['invoicePackages', 'packingPackages', 'blPackages']);
const CODE_FIELDS = new Set(['invoice', 'hsn', 'container']);

export function sanitizeFieldInput(fieldKey, value) {
  const input = String(value ?? '').replace(/[\u0000-\u001f\u007f]/g, '');
  if (fieldKey === 'currency') return input.replace(/[^a-z]/gi, '').slice(0, 3).toUpperCase();
  if (NUMERIC_FIELDS.has(fieldKey)) {
    const cleaned = input.replace(/[^\d.]/g, '');
    const dot = cleaned.indexOf('.');
    return dot < 0 ? cleaned : `${cleaned.slice(0, dot)}.${cleaned.slice(dot + 1).replaceAll('.', '')}`;
  }
  if (INTEGER_FIELDS.has(fieldKey)) return input.replace(/\D/g, '');
  if (CODE_FIELDS.has(fieldKey)) return input.replace(/[^\p{L}\p{N} ./_-]/gu, '').slice(0, 80);
  if (fieldKey === 'packages') return input.replace(/[^\p{L}\p{N} .,_/-]/gu, '').slice(0, 80);
  return input.slice(0, 240);
}

export function inputPropsForField(fieldKey) {
  if (NUMERIC_FIELDS.has(fieldKey)) return { inputMode: 'decimal', type: 'text', autoComplete: 'off' };
  if (INTEGER_FIELDS.has(fieldKey)) return { inputMode: 'numeric', type: 'text', autoComplete: 'off' };
  return { type: 'text', autoComplete: 'off' };
}
