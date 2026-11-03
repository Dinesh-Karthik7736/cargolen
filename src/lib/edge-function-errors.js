const readResponseBody = async (response) => {
  if (!response || typeof response.clone !== 'function') return null;
  try {
    const body = await response.clone().json();
    return typeof body?.error === 'string' ? body.error : typeof body?.message === 'string' ? body.message : null;
  } catch {
    return null;
  }
};

export async function extractionErrorMessage(error) {
  const response = error?.context;
  const status = Number(response?.status) || null;
  const detail = await readResponseBody(response);

  if (status === 404) return 'The extract-document function is not deployed to this Supabase project yet.';
  if (status === 401) return 'Your sign-in expired. Sign in again, then retry extraction.';
  if (status === 403) return detail || 'Extraction is available to active documentation executives only.';
  if (status === 503) return detail || 'The extraction service is not configured. Add LLAMA_CLOUD_API_KEY to Supabase Function secrets.';
  if (status === 415) return detail || 'This file type or size is not supported.';
  if (status === 409) return detail || 'This document is already processing or is not available to extract.';
  if (status === 422) return detail || 'The AI could not extract this document. Check the function logs for details.';
  if (status) return detail ? `Extraction failed (HTTP ${status}): ${detail}` : `Extraction failed with HTTP ${status}. Check the Supabase function logs.`;
  return 'Could not reach the extraction function. Check your connection and the Supabase function deployment.';
}

