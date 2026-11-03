import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/document-extraction-golden.json', import.meta.url), 'utf8'));
const sampleDir = join(process.cwd(), 'public', 'samples');

test('clean shipment sample has a deliberate 45 kg cross-document mismatch', () => {
  const sample = fixture['SHP-24811'];
  assert.equal(sample.expected_cross_document_result.gross_weight_matches_all_documents, false);
  assert.equal(sample.invoice.invoice_total, sample.invoice.line_items.reduce((sum, item) => sum + item.line_total, 0));
  assert.equal(sample.invoice.gross_weight_kg, 3120);
  assert.equal(sample.packing_list.gross_weight_kg, 3165);
  assert.equal(sample.bill_of_lading.gross_weight_kg, 3120);
});

test('imperfect scan sample is labeled with matching weights and packages', () => {
  const sample = fixture['SHP-24812'];
  assert.equal(sample.expected_cross_document_result.gross_weight_matches_all_documents, true);
  assert.equal(sample.expected_cross_document_result.package_count_matches_all_documents, true);
  assert.equal(sample.invoice.invoice_total, sample.invoice.line_items.reduce((sum, item) => sum + item.line_total, 0));
  assert.match(sample.quality, /image-only scans/i);
});

test('all six synthetic PDFs referenced by the sample workflow exist', () => {
  const files = [
    'SHP-24811-invoice.pdf', 'SHP-24811-packing-list.pdf', 'SHP-24811-bill-of-lading.pdf',
    'SHP-24812-invoice-scan.pdf', 'SHP-24812-packing-list-scan.pdf', 'SHP-24812-bill-of-lading-scan.pdf',
  ];
  for (const file of files) assert.equal(existsSync(join(sampleDir, file)), true, `${file} should exist`);
});
