-- CargoLens single-company schema. Apply to a NEW Supabase project in ap-south-1.
-- No client receives service-role access. Approval and audit writes are server/database controlled.

create extension if not exists pgcrypto with schema extensions;

create type public.app_role as enum ('executive', 'manager');
create type public.shipment_status as enum (
  'in_progress', 'needs_review', 'ready_for_approval', 'approved', 'exported'
);
create type public.shipment_document_type as enum ('invoice', 'packing_list', 'bill_of_lading');

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role public.app_role not null default 'executive',
  disabled_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.create_profile_for_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger auth_user_profile_created
after insert on auth.users
for each row execute function public.create_profile_for_auth_user();

create or replace function public.current_user_role()
returns public.app_role language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p
  where p.user_id = (select auth.uid()) and p.disabled_at is null
$$;

create table public.shipments (
  id uuid primary key default gen_random_uuid(),
  shipment_no text not null unique default ('SHP-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(gen_random_uuid()::text, 1, 6))),
  supplier_name text not null default '',
  supplier_country text,
  port_name text not null default 'Nhava Sheva',
  shipment_date date,
  status public.shipment_status not null default 'in_progress',
  invoice_number text,
  invoice_date date,
  currency char(3),
  incoterm text,
  invoice_total numeric(18, 2),
  package_count integer,
  package_type text,
  gross_weight_kg numeric(14, 3),
  net_weight_kg numeric(14, 3),
  container_numbers text[] not null default '{}',
  extraction_confidence jsonb not null default '{}',
  review_required_fields text[] not null default '{}',
  confirmed_fields text[] not null default '{}',
  submitted_by uuid references public.profiles(user_id),
  submitted_at timestamptz,
  approved_by uuid references public.profiles(user_id),
  approved_at timestamptz,
  created_by uuid not null default auth.uid() references public.profiles(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint shipments_currency_code check (currency is null or currency ~ '^[A-Z]{3}$'),
  constraint shipments_positive_packages check (package_count is null or package_count >= 0),
  constraint shipments_nonnegative_weights check (
    (gross_weight_kg is null or gross_weight_kg >= 0) and
    (net_weight_kg is null or net_weight_kg >= 0)
  )
);

create table public.shipment_items (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  line_number integer not null,
  description text not null default '',
  hsn_code text,
  quantity numeric(18, 4),
  unit_price numeric(18, 4),
  line_total numeric(18, 2),
  confidence jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shipment_id, line_number),
  constraint shipment_items_positive_line check (line_number > 0),
  constraint shipment_items_nonnegative check (
    (quantity is null or quantity >= 0) and
    (unit_price is null or unit_price >= 0) and
    (line_total is null or line_total >= 0)
  )
);

create table public.shipment_documents (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  document_type public.shipment_document_type not null,
  object_path text not null unique,
  original_filename text not null,
  mime_type text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  size_bytes bigint not null check (size_bytes between 1 and 20971520),
  sha256 text,
  processing_status text not null default 'uploaded'
    check (processing_status in ('uploaded', 'queued', 'processing', 'complete', 'manual_entry', 'failed')),
  page_count integer,
  ocr_text text,
  extracted_data jsonb not null default '{}',
  reviewed_data jsonb not null default '{}',
  field_confidence jsonb not null default '{}',
  extraction_provider text,
  extraction_model text,
  failure_reason text,
  uploaded_by uuid not null default auth.uid() references public.profiles(user_id),
  uploaded_at timestamptz not null default now(),
  extracted_at timestamptz,
  reviewed_at timestamptz,
  constraint shipment_documents_one_type unique (shipment_id, document_type)
);

create table public.shipment_audit (
  id bigint generated always as identity primary key,
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  actor_id uuid references public.profiles(user_id),
  entity text not null,
  entity_id uuid not null,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  created_at timestamptz not null default now()
);

create index shipments_status_updated_idx on public.shipments (status, updated_at desc);
create index shipments_supplier_idx on public.shipments (lower(supplier_name));
create index shipments_created_by_idx on public.shipments (created_by);
create index shipment_items_parent_idx on public.shipment_items (shipment_id, line_number);
create index shipment_documents_parent_idx on public.shipment_documents (shipment_id, document_type);
create index shipment_audit_parent_time_idx on public.shipment_audit (shipment_id, created_at desc);
create index shipment_audit_actor_time_idx on public.shipment_audit (actor_id, created_at desc);

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger shipments_touch_updated_at before update on public.shipments
for each row execute function public.touch_updated_at();
create trigger shipment_items_touch_updated_at before update on public.shipment_items
for each row execute function public.touch_updated_at();

create or replace function public.audit_row_update()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  before_row jsonb := to_jsonb(old);
  after_row jsonb := to_jsonb(new);
  field record;
begin
  for field in select key from jsonb_each(after_row)
  loop
    if field.key not in ('updated_at', 'reviewed_at')
       and before_row -> field.key is distinct from after_row -> field.key then
      insert into public.shipment_audit (
        shipment_id, actor_id, entity, entity_id, field_name, old_value, new_value
      ) values (
        coalesce((after_row ->> 'shipment_id')::uuid, (after_row ->> 'id')::uuid),
        auth.uid(), tg_table_name, (after_row ->> 'id')::uuid, field.key,
        before_row -> field.key, after_row -> field.key
      );
    end if;
  end loop;
  return new;
end;
$$;

create trigger shipments_audit_update after update on public.shipments
for each row execute function public.audit_row_update();
create trigger shipment_items_audit_update after update on public.shipment_items
for each row execute function public.audit_row_update();
create trigger shipment_documents_audit_update after update on public.shipment_documents
for each row execute function public.audit_row_update();

create or replace function public.submit_shipment_for_approval(p_shipment_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  s public.shipments%rowtype;
  doc_count integer;
  item_count integer;
  item_sum numeric(18, 2);
  weights numeric[];
  packages integer[];
begin
  if public.current_user_role() is distinct from 'executive'::public.app_role then
    raise exception 'Only an active executive can submit a shipment';
  end if;
  select * into s from public.shipments where id = p_shipment_id for update;
  if not found or s.status not in ('in_progress', 'needs_review') then
    raise exception 'Shipment is not available for submission';
  end if;
  select count(*) into doc_count from public.shipment_documents
    where shipment_id = p_shipment_id and processing_status in ('complete', 'manual_entry');
  if doc_count <> 3 or (select count(distinct document_type) from public.shipment_documents where shipment_id=p_shipment_id and processing_status in ('complete','manual_entry')) <> 3 then
    raise exception 'All three document types must be reviewed';
  end if;
  select count(*), coalesce(sum(line_total), 0) into item_count, item_sum
    from public.shipment_items where shipment_id = p_shipment_id;
  if item_count = 0 then raise exception 'At least one confirmed line item is required'; end if;
  if exists (select 1 from public.shipment_items where shipment_id=p_shipment_id
    and (btrim(description)='' or hsn_code is null or btrim(hsn_code)='' or quantity is null or quantity<=0 or unit_price is null or line_total is null
      or abs(line_total - round(quantity * unit_price, 2)) > 0.01)) then
    raise exception 'Complete each line item description, HSN, quantity and unit price';
  end if;
  if btrim(s.supplier_name)='' or btrim(coalesce(s.invoice_number,''))='' or s.currency is null or btrim(coalesce(s.incoterm,''))='' then
    raise exception 'Confirm supplier, invoice number, currency and Incoterm';
  end if;
  if s.invoice_total is null or abs(s.invoice_total - item_sum) > 0.01 then
    raise exception 'Invoice total does not match the line item sum';
  end if;
  if exists (
    select 1 from unnest(s.review_required_fields) as required(field)
    where not (required.field = any(s.confirmed_fields))
  ) then
    raise exception 'Low-confidence fields must be confirmed';
  end if;
  select array_agg(((d.extracted_data || d.reviewed_data) ->> 'gross_weight_kg')::numeric)
    into weights from public.shipment_documents d where d.shipment_id = p_shipment_id;
  if weights is null or cardinality(weights) <> 3 or array_position(weights, null) is not null
     or (select min(value) <> max(value) from unnest(weights) as w(value)) then
    raise exception 'Gross weights must match across all documents';
  end if;
  select array_agg(((d.extracted_data || d.reviewed_data) ->> 'package_count')::integer)
    into packages from public.shipment_documents d where d.shipment_id = p_shipment_id;
  if packages is null or cardinality(packages) <> 3 or array_position(packages, null) is not null
     or (select min(value) <> max(value) from unnest(packages) as p(value)) then
    raise exception 'Package counts must match across all documents';
  end if;
  update public.shipments set status='ready_for_approval', submitted_by=auth.uid(), submitted_at=now()
    where id=p_shipment_id;
end;
$$;

create or replace function public.approve_shipment(p_shipment_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.current_user_role() is distinct from 'manager'::public.app_role then
    raise exception 'Only an active manager can approve a shipment';
  end if;
  update public.shipments set status='approved', approved_by=auth.uid(), approved_at=now()
    where id=p_shipment_id and status='ready_for_approval' and submitted_by is distinct from auth.uid();
  if not found then raise exception 'Shipment is not ready for approval by a different manager'; end if;
end;
$$;

create or replace function public.mark_document_manual_entry(p_document_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.current_user_role() is distinct from 'executive'::public.app_role then
    raise exception 'Only an active executive can mark a document for manual entry';
  end if;
  update public.shipment_documents d
    set processing_status='manual_entry', failure_reason=null
    from public.shipments s
    where d.id=p_document_id and s.id=d.shipment_id and s.status in ('in_progress','needs_review');
  if not found then raise exception 'Document is not available for manual entry'; end if;
end;
$$;

alter table public.profiles enable row level security;
alter table public.shipments enable row level security;
alter table public.shipment_items enable row level security;
alter table public.shipment_documents enable row level security;
alter table public.shipment_audit enable row level security;

revoke all on public.profiles, public.shipments, public.shipment_items, public.shipment_documents, public.shipment_audit from anon;
revoke all on function public.submit_shipment_for_approval(uuid) from public, anon;
revoke all on function public.approve_shipment(uuid) from public, anon;
revoke all on function public.mark_document_manual_entry(uuid) from public, anon;
grant select on public.profiles, public.shipments, public.shipment_items, public.shipment_documents, public.shipment_audit to authenticated;
grant insert (supplier_name, supplier_country, port_name, shipment_date, invoice_number, invoice_date, currency, incoterm, invoice_total, package_count, package_type, gross_weight_kg, net_weight_kg, container_numbers, extraction_confidence, review_required_fields, confirmed_fields)
  on public.shipments to authenticated;
grant update (supplier_name, supplier_country, port_name, shipment_date, invoice_number, invoice_date, currency, incoterm, invoice_total, package_count, package_type, gross_weight_kg, net_weight_kg, container_numbers, confirmed_fields)
  on public.shipments to authenticated;
grant insert (shipment_id, line_number, description, hsn_code, quantity, unit_price, line_total, confidence)
  on public.shipment_items to authenticated;
grant update (description, hsn_code, quantity, unit_price, line_total, confidence)
  on public.shipment_items to authenticated;
grant insert (shipment_id, document_type, object_path, original_filename, mime_type, size_bytes, sha256)
  on public.shipment_documents to authenticated;
grant update (reviewed_data, reviewed_at)
  on public.shipment_documents to authenticated;
grant update (processing_status, page_count, ocr_text, extracted_data, field_confidence,
  extraction_provider, extraction_model, failure_reason, extracted_at)
  on public.shipment_documents to service_role;
revoke execute on function public.current_user_role() from public, anon;
grant execute on function public.current_user_role() to authenticated;
grant execute on function public.submit_shipment_for_approval(uuid) to authenticated;
grant execute on function public.approve_shipment(uuid) to authenticated;
grant execute on function public.mark_document_manual_entry(uuid) to authenticated;

create policy profiles_self_read on public.profiles for select to authenticated
  using (user_id=(select auth.uid()) or (select public.current_user_role())='manager'::public.app_role);
create policy shipments_read on public.shipments for select to authenticated
  using ((select public.current_user_role()) is not null);
create policy shipments_insert on public.shipments for insert to authenticated
  with check ((select public.current_user_role())='executive'::public.app_role
    and created_by=(select auth.uid()));
create policy shipments_edit on public.shipments for update to authenticated
  using ((select public.current_user_role())='executive'::public.app_role
    and status in ('in_progress', 'needs_review'))
  with check ((select public.current_user_role())='executive'::public.app_role
    and status in ('in_progress', 'needs_review'));

create policy items_read on public.shipment_items for select to authenticated
  using (exists (select 1 from public.shipments s where s.id=shipment_id));
create policy items_insert on public.shipment_items for insert to authenticated
  with check ((select public.current_user_role())='executive'::public.app_role
    and exists (select 1 from public.shipments s where s.id=shipment_id and s.status in ('in_progress','needs_review')));
create policy items_edit on public.shipment_items for update to authenticated
  using ((select public.current_user_role())='executive'::public.app_role
    and exists (select 1 from public.shipments s where s.id=shipment_id and s.status in ('in_progress','needs_review')))
  with check ((select public.current_user_role())='executive'::public.app_role);

create policy documents_read on public.shipment_documents for select to authenticated
  using (exists (select 1 from public.shipments s where s.id=shipment_id));
create policy documents_insert on public.shipment_documents for insert to authenticated
  with check ((select public.current_user_role())='executive'::public.app_role
    and uploaded_by=(select auth.uid())
    and exists (select 1 from public.shipments s where s.id=shipment_id and s.status in ('in_progress','needs_review')));
create policy documents_review on public.shipment_documents for update to authenticated
  using ((select public.current_user_role())='executive'::public.app_role
    and exists (select 1 from public.shipments s where s.id=shipment_id and s.status in ('in_progress','needs_review')))
  with check ((select public.current_user_role())='executive'::public.app_role);
create policy audit_read on public.shipment_audit for select to authenticated
  using ((select public.current_user_role()) is not null);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shipment-documents', 'shipment-documents', false, 20971520,
  array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false, file_size_limit=20971520,
  allowed_mime_types=array['application/pdf','image/jpeg','image/png','image/webp'];

create policy shipment_files_read on storage.objects for select to authenticated
  using (bucket_id='shipment-documents'
    and exists (select 1 from public.shipments s
      where s.id=(storage.foldername(name))[1]::uuid));
create policy shipment_files_insert on storage.objects for insert to authenticated
  with check (bucket_id='shipment-documents'
    and (select public.current_user_role())='executive'::public.app_role
    and exists (select 1 from public.shipments s
      where s.id=(storage.foldername(name))[1]::uuid and s.status in ('in_progress','needs_review')));
create policy shipment_files_delete on storage.objects for delete to authenticated
  using (bucket_id='shipment-documents'
    and (select public.current_user_role())='executive'::public.app_role
    and exists (select 1 from public.shipments s
      where s.id=(storage.foldername(name))[1]::uuid and s.status in ('in_progress','needs_review')));
