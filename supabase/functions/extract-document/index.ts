import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const headersFor = (origin: string) => {
  const allowed = (Deno.env.get('APP_ORIGINS') || 'http://localhost:5173,http://localhost:5174')
    .split(',').map((value) => value.trim()).filter(Boolean);
  const corsOrigin = allowed.includes(origin) ? origin : allowed[0];
  return {
    'Access-Control-Allow-Origin': corsOrigin,
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
    'Content-Type': 'application/json',
  };
};

const schema = {
  type: 'object',
  properties: {
    supplier_name: { type: 'string', description: 'Supplier or shipper name exactly as printed.' },
    supplier_country: { type: 'string', description: 'Supplier country, only when shown.' },
    buyer_name: { type: 'string', description: 'Buyer or consignee name exactly as printed.' },
    invoice_number: { type: 'string', description: 'Invoice number, when shown.' },
    invoice_date: { type: 'string', description: 'Invoice date in ISO YYYY-MM-DD format, when shown.' },
    currency: { type: 'string', description: 'Three-letter currency code, when shown.' },
    incoterm: { type: 'string', description: 'Incoterm exactly as shown, when shown.' },
    invoice_total: { type: 'number', description: 'Final invoice total as a number, when shown.' },
    package_count: { type: 'number', description: 'Number of packages, when shown.' },
    package_type: { type: 'string', description: 'Package type, such as cartons or pallets.' },
    gross_weight_kg: { type: 'number', description: 'Gross weight in kilograms, when shown.' },
    net_weight_kg: { type: 'number', description: 'Net weight in kilograms, when shown.' },
    container_numbers: { type: 'string', description: 'Container identifiers, separated by commas.' },
    line_items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          description: { type: 'string', description: 'Goods description exactly as shown.' },
          hsn_code: { type: 'string', description: 'HSN code only if printed; never infer or classify.' },
          quantity: { type: 'number', description: 'Quantity as a number.' },
          unit_price: { type: 'number', description: 'Unit price as a number.' },
          line_total: { type: 'number', description: 'Line amount as a number.' },
        },
      },
    },
  },
};

const confidenceNumber = (value: unknown) => {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(1, Math.max(0, number)) : 0;
};

const providerError = async (response: Response, action: string) => {
  let detail = '';
  try {
    const body = await response.json();
    detail = String(body.detail || body.message || body.error || '').slice(0, 180);
  } catch { /* keep the user-facing message generic */ }
  const status = response.status;
  if (status === 401 || status === 403) return `LlamaCloud rejected the API key or project access (HTTP ${status}). Check the Supabase Function secrets.`;
  if (status === 402) return 'LlamaCloud free-tier credits are exhausted. Check the LlamaCloud usage page and retry after the monthly reset.';
  if (status === 429) return 'LlamaCloud rate limit reached. Wait briefly, then retry extraction.';
  if ([502, 503, 504].includes(status)) return `LlamaCloud is temporarily unavailable (HTTP ${status}). Retry extraction in a moment.`;
  return `LlamaCloud could not ${action} (HTTP ${status})${detail ? `: ${detail}` : '.'}`;
};

Deno.serve(async (request) => {
  const cors = headersFor(request.headers.get('origin') || '');
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (request.method !== 'POST') return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405, headers: cors });

  const url = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const llamaKey = Deno.env.get('LLAMA_CLOUD_API_KEY');
  const llamaProject = Deno.env.get('LLAMA_CLOUD_PROJECT_ID');
  if (!url || !anonKey || !serviceKey || !llamaKey) {
    return new Response(JSON.stringify({ error: 'Extraction service is not configured. Add LLAMA_CLOUD_API_KEY to Supabase Function secrets.' }), { status: 503, headers: cors });
  }

  const authorization = request.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ')) return new Response(JSON.stringify({ error: 'Sign in to extract shipment documents.' }), { status: 401, headers: cors });
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) return new Response(JSON.stringify({ error: 'Your session has expired. Sign in again.' }), { status: 401, headers: cors });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: profile } = await admin.from('profiles').select('role,disabled_at').eq('user_id', user.id).maybeSingle();
  if (!profile || profile.disabled_at || profile.role !== 'executive') return new Response(JSON.stringify({ error: 'Only active documentation executives can run extraction.' }), { status: 403, headers: cors });

  let documentId: string;
  try {
    const body = await request.json();
    documentId = String(body.document_id || '');
    if (!/^[0-9a-f-]{36}$/i.test(documentId)) throw new Error('Invalid document ID.');
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Invalid request.' }), { status: 400, headers: cors });
  }

  const { data: document, error: documentError } = await admin.from('shipment_documents')
    .select('id,shipment_id,document_type,object_path,mime_type,size_bytes,processing_status')
    .eq('id', documentId).maybeSingle();
  if (documentError || !document) return new Response(JSON.stringify({ error: 'Document not found.' }), { status: 404, headers: cors });
  if (!['application/pdf','image/jpeg','image/png','image/webp'].includes(document.mime_type) || document.size_bytes > 20 * 1024 * 1024) {
    return new Response(JSON.stringify({ error: 'This file type or size is not supported.' }), { status: 415, headers: cors });
  }
  if (!['uploaded','failed'].includes(document.processing_status)) return new Response(JSON.stringify({ error: 'This document is already being processed or reviewed.' }), { status: 409, headers: cors });
  const { data: claimed, error: claimError } = await admin.from('shipment_documents').update({ processing_status: 'processing', failure_reason: null })
    .eq('id', documentId).in('processing_status', ['uploaded','failed']).select('id').maybeSingle();
  if (claimError || !claimed) return new Response(JSON.stringify({ error: 'Another extraction is already running for this document.' }), { status: 409, headers: cors });

  try {
    const { data: file, error: fileError } = await admin.storage.from('shipment-documents').download(document.object_path);
    if (fileError || !file) throw new Error('The private source file could not be opened.');
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (bytes.byteLength === 0 || bytes.byteLength > 20 * 1024 * 1024) throw new Error('The source file is empty or exceeds the 20 MB limit.');
    const apiRoot = 'https://api.cloud.llamaindex.ai';
    const projectParam = llamaProject ? `?project_id=${encodeURIComponent(llamaProject)}` : '';
    const headers = { Authorization: `Bearer ${llamaKey}` };
    const uploadBody = new FormData();
    uploadBody.append('purpose', 'extract');
    uploadBody.append('file', new Blob([bytes], { type: document.mime_type }), document.object_path.split('/').pop() || `${document.document_type}.pdf`);
    const uploadResponse = await fetch(`${apiRoot}/api/v1/beta/files`, { method: 'POST', headers, body: uploadBody });
    if (!uploadResponse.ok) throw new Error(await providerError(uploadResponse, 'upload'));
    const uploaded = await uploadResponse.json();
    if (typeof uploaded.id !== 'string') throw new Error('LlamaCloud did not return an uploaded file ID.');

    const createResponse = await fetch(`${apiRoot}/api/v2/extract${projectParam}`, {
      method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ file_input: uploaded.id, configuration: {
        tier: Deno.env.get('LLAMA_EXTRACT_TIER') || 'cost_effective', version: 'latest', extraction_target: 'per_doc',
        data_schema: schema, cite_sources: true, confidence_scores: true,
        system_prompt: `Read this shipment ${document.document_type.replaceAll('_', ' ')}. The scan may be skewed or bilingual. Extract only printed values; do not infer missing data, classify HSN, or calculate duty. Return absent fields as null and absent line_items as an empty array. Normalize weights to kilograms and dates to YYYY-MM-DD.`,
      } }),
    });
    if (!createResponse.ok) throw new Error(await providerError(createResponse, 'start extraction'));
    const created = await createResponse.json();
    if (typeof created.id !== 'string') throw new Error('LlamaCloud did not return an extraction job ID.');
    let completed = created;
    const deadline = Date.now() + 105_000;
    while (!['COMPLETED', 'FAILED', 'CANCELLED'].includes(completed.status) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 2000));
      const pollResponse = await fetch(`${apiRoot}/api/v2/extract/${encodeURIComponent(created.id)}${projectParam}`, { headers });
      if (!pollResponse.ok) throw new Error(await providerError(pollResponse, 'check extraction status'));
      completed = await pollResponse.json();
    }
    if (!['COMPLETED', 'FAILED', 'CANCELLED'].includes(completed.status)) throw new Error('LlamaCloud extraction is taking longer than expected. Retry in a moment.');
    if (completed.status !== 'COMPLETED') throw new Error(`LlamaCloud could not process this document${completed.error_message ? `: ${String(completed.error_message).slice(0, 180)}` : '.'}`);
    const resultResponse = await fetch(`${apiRoot}/api/v2/extract/${encodeURIComponent(created.id)}${projectParam ? `${projectParam}&` : '?'}expand=extract_metadata`, { headers });
    if (!resultResponse.ok) throw new Error(await providerError(resultResponse, 'retrieve extraction result'));
    const job = await resultResponse.json();
    const result = job.extract_result;
    if (!result || typeof result !== 'object' || Array.isArray(result) || (result.line_items != null && !Array.isArray(result.line_items))) throw new Error('LlamaCloud result failed shipment schema validation.');
    if (!Array.isArray(result.line_items)) result.line_items = [];
    const metadata = job.extract_metadata?.field_metadata?.document_metadata || {};
    const fields = Object.fromEntries(Object.keys(schema.properties).filter((key) => key !== 'line_items').map((key) => [key, result[key]]));

    const plainFields: Record<string, unknown> = {};
    const confidence: Record<string, number> = {};
    const evidence: Record<string, string | null> = {};
    const reviewRequired: string[] = [];
    for (const [key, value] of Object.entries(fields)) {
      const fieldMetadata = metadata[key] || {};
      const score = confidenceNumber(fieldMetadata.confidence);
      plainFields[key] = value ?? null;
      confidence[key] = Math.round(score * 100);
      const citation = Array.isArray(fieldMetadata.citation) ? fieldMetadata.citation[0] : null;
      evidence[key] = typeof citation?.matching_text === 'string' ? citation.matching_text.slice(0, 240) : null;
      if (score < 0.82) reviewRequired.push(`${document.document_type}.${key}`);
    }
    const lineItems = result.line_items.slice(0, 200).map((item: Record<string, unknown>, index: number) => {
      const values: Record<string, unknown> = {};
      const itemConfidence: Record<string, number> = {};
      const itemEvidence: Record<string, string | null> = {};
      const itemMetadata = metadata.line_items?.[index] || {};
      for (const key of ['description','hsn_code','quantity','unit_price','line_total']) {
        const score = confidenceNumber(itemMetadata[key]?.confidence);
        values[key] = item[key] ?? null; itemConfidence[key] = Math.round(score * 100);
        const citation = Array.isArray(itemMetadata[key]?.citation) ? itemMetadata[key].citation[0] : null;
        itemEvidence[key] = typeof citation?.matching_text === 'string' ? citation.matching_text.slice(0, 240) : null;
        if (score < 0.82) reviewRequired.push(`${document.document_type}.items.${index + 1}.${key}`);
      }
      return { ...values, confidence: itemConfidence, evidence: itemEvidence, line_number: index + 1 };
    });

    const { error: updateDocError } = await admin.from('shipment_documents').update({
      processing_status: 'complete', extracted_data: { ...plainFields, line_items: lineItems, _evidence: evidence },
      field_confidence: confidence, extraction_provider: 'LlamaCloud Extract', extraction_model: `LlamaExtract ${Deno.env.get('LLAMA_EXTRACT_TIER') || 'cost_effective'}`,
      extracted_at: new Date().toISOString(), failure_reason: null,
    }).eq('id', documentId);
    if (updateDocError) throw new Error('Could not save the validated extraction result.');

    const { data: shipment } = await admin.from('shipments').select('review_required_fields').eq('id', document.shipment_id).single();
    const pending = [...new Set([...(shipment?.review_required_fields || []), ...reviewRequired])];
    if (document.document_type === 'invoice') {
      const number = (value: unknown) => value === null || value === undefined || value === '' ? null : Number(value);
      const containers = String(plainFields.container_numbers || '').split(/[;,\n]/).map((value) => value.trim()).filter(Boolean);
      const { error: shipmentError } = await admin.from('shipments').update({
        supplier_name: String(plainFields.supplier_name || ''), supplier_country: plainFields.supplier_country || null,
        invoice_number: plainFields.invoice_number || null, invoice_date: plainFields.invoice_date || null,
        currency: plainFields.currency ? String(plainFields.currency).toUpperCase().slice(0, 3) : null,
        incoterm: plainFields.incoterm || null, invoice_total: number(plainFields.invoice_total),
        package_count: number(plainFields.package_count), package_type: plainFields.package_type || null,
        gross_weight_kg: number(plainFields.gross_weight_kg), net_weight_kg: number(plainFields.net_weight_kg),
        container_numbers: containers, review_required_fields: pending,
      }).eq('id', document.shipment_id);
      if (shipmentError) throw new Error('Could not save invoice fields.');
      if (lineItems.length) {
        const rows = lineItems.map((item: Record<string, unknown>) => ({
          shipment_id: document.shipment_id, line_number: item.line_number, description: String(item.description || ''),
          hsn_code: item.hsn_code ? String(item.hsn_code).slice(0, 24) : null,
          quantity: item.quantity === null ? null : Number(item.quantity), unit_price: item.unit_price === null ? null : Number(item.unit_price),
          line_total: item.line_total === null ? null : Number(item.line_total), confidence: item.confidence,
        }));
        const { error: itemError } = await admin.from('shipment_items').upsert(rows, { onConflict: 'shipment_id,line_number' });
        if (itemError) throw new Error('Could not save extracted line items.');
      }
    } else {
      const { error: shipmentError } = await admin.from('shipments').update({ review_required_fields: pending }).eq('id', document.shipment_id);
      if (shipmentError) throw new Error('Could not save review requirements.');
    }
    return new Response(JSON.stringify({ status: 'complete', review_required_fields: reviewRequired }), { status: 200, headers: cors });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Document extraction failed.';
    await admin.from('shipment_documents').update({ processing_status: 'failed', failure_reason: message.slice(0, 300) }).eq('id', documentId);
    return new Response(JSON.stringify({ error: message }), { status: 422, headers: cors });
  }
});

