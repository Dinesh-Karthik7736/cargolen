-- Separate executive work from manager decisions and preserve an immutable decision history.

create sequence if not exists public.staff_code_seq;
alter table public.profiles add column if not exists staff_code text;

update public.profiles
set staff_code = (case when role = 'manager'::public.app_role then 'MGR-' else 'EXE-' end)
  || lpad(nextval('public.staff_code_seq')::text, 5, '0')
where staff_code is null;

select setval(
  'public.staff_code_seq',
  coalesce((select max(substring(staff_code from '[0-9]+$')::bigint) from public.profiles), 0) + 1,
  false
);

alter table public.profiles add constraint profiles_staff_code_unique unique (staff_code);

create or replace function public.assign_staff_code()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.staff_code is null then
    new.staff_code := (case when new.role = 'manager'::public.app_role then 'MGR-' else 'EXE-' end)
      || lpad(nextval('public.staff_code_seq')::text, 5, '0');
  end if;
  return new;
end;
$$;
revoke execute on function public.assign_staff_code() from public, anon, authenticated;
create trigger profiles_assign_staff_code
before insert on public.profiles
for each row execute function public.assign_staff_code();

create table public.shipment_approval_events (
  id bigint generated always as identity primary key,
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  executive_id uuid not null references public.profiles(user_id),
  actor_id uuid not null references public.profiles(user_id),
  decision text not null check (decision in ('submitted', 'approved', 'rejected', 'returned_for_correction')),
  note text,
  created_at timestamptz not null default now(),
  constraint approval_decision_note_required check (
    decision not in ('rejected', 'returned_for_correction') or nullif(btrim(note), '') is not null
  )
);

create index shipment_approval_events_shipment_time_idx
  on public.shipment_approval_events (shipment_id, created_at desc);
create index shipment_approval_events_executive_time_idx
  on public.shipment_approval_events (executive_id, created_at desc);
create index shipments_owner_status_created_idx
  on public.shipments (created_by, status, created_at desc);

alter table public.shipment_approval_events enable row level security;
revoke all on public.shipment_approval_events from anon, authenticated;
grant select on public.shipment_approval_events to authenticated;

create policy approval_events_read on public.shipment_approval_events for select to authenticated
  using (
    (select public.current_user_role()) = 'manager'::public.app_role
    or ((select public.current_user_role()) = 'executive'::public.app_role
      and executive_id = (select auth.uid()))
  );

drop policy shipments_read on public.shipments;
create policy shipments_read on public.shipments for select to authenticated
  using (
    (select public.current_user_role()) = 'manager'::public.app_role
    or ((select public.current_user_role()) = 'executive'::public.app_role
      and created_by = (select auth.uid()))
  );

drop policy shipments_edit on public.shipments;
create policy shipments_edit on public.shipments for update to authenticated
  using (
    (select public.current_user_role()) = 'executive'::public.app_role
    and created_by = (select auth.uid())
    and status in ('in_progress', 'needs_review')
  )
  with check (
    (select public.current_user_role()) = 'executive'::public.app_role
    and created_by = (select auth.uid())
    and status in ('in_progress', 'needs_review')
  );

drop policy items_insert on public.shipment_items;
create policy items_insert on public.shipment_items for insert to authenticated
  with check (
    (select public.current_user_role()) = 'executive'::public.app_role
    and exists (select 1 from public.shipments s where s.id = shipment_id
      and s.created_by = (select auth.uid()) and s.status in ('in_progress', 'needs_review'))
  );
drop policy items_edit on public.shipment_items;
create policy items_edit on public.shipment_items for update to authenticated
  using (
    (select public.current_user_role()) = 'executive'::public.app_role
    and exists (select 1 from public.shipments s where s.id = shipment_id
      and s.created_by = (select auth.uid()) and s.status in ('in_progress', 'needs_review'))
  )
  with check ((select public.current_user_role()) = 'executive'::public.app_role);

drop policy documents_insert on public.shipment_documents;
create policy documents_insert on public.shipment_documents for insert to authenticated
  with check (
    (select public.current_user_role()) = 'executive'::public.app_role
    and uploaded_by = (select auth.uid())
    and exists (select 1 from public.shipments s where s.id = shipment_id
      and s.created_by = (select auth.uid()) and s.status in ('in_progress', 'needs_review'))
  );
drop policy documents_review on public.shipment_documents;
create policy documents_review on public.shipment_documents for update to authenticated
  using (
    (select public.current_user_role()) = 'executive'::public.app_role
    and exists (select 1 from public.shipments s where s.id = shipment_id
      and s.created_by = (select auth.uid()) and s.status in ('in_progress', 'needs_review'))
  )
  with check ((select public.current_user_role()) = 'executive'::public.app_role);
drop policy documents_delete on public.shipment_documents;
create policy documents_delete on public.shipment_documents for delete to authenticated
  using (
    (select public.current_user_role()) = 'executive'::public.app_role
    and exists (select 1 from public.shipments s where s.id = shipment_id
      and s.created_by = (select auth.uid()) and s.status in ('in_progress', 'needs_review'))
  );

drop policy audit_read on public.shipment_audit;
create policy audit_read on public.shipment_audit for select to authenticated
  using (
    (select public.current_user_role()) = 'manager'::public.app_role
    or ((select public.current_user_role()) = 'executive'::public.app_role
      and exists (select 1 from public.shipments s where s.id = shipment_id
        and s.created_by = (select auth.uid())))
  );

drop policy shipment_files_insert on storage.objects;
create policy shipment_files_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'shipment-documents'
    and (select public.current_user_role()) = 'executive'::public.app_role
    and exists (select 1 from public.shipments s
      where s.id = (storage.foldername(name))[1]::uuid
        and s.created_by = (select auth.uid()) and s.status in ('in_progress', 'needs_review'))
  );
drop policy shipment_files_delete on storage.objects;
create policy shipment_files_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'shipment-documents'
    and (select public.current_user_role()) = 'executive'::public.app_role
    and exists (select 1 from public.shipments s
      where s.id = (storage.foldername(name))[1]::uuid
        and s.created_by = (select auth.uid()) and s.status in ('in_progress', 'needs_review'))
  );

create or replace function public.submit_shipment_for_approval(p_shipment_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  s public.shipments%rowtype;
  item_count integer;
  item_sum numeric(18, 2);
  weights numeric[];
  packages integer[];
begin
  if public.current_user_role() is distinct from 'executive'::public.app_role then
    raise exception 'Only an active executive can submit a shipment';
  end if;
  select * into s from public.shipments where id = p_shipment_id for update;
  if not found or s.created_by is distinct from (select auth.uid())
     or s.status not in ('in_progress', 'needs_review') then
    raise exception 'Shipment is not available for submission by this executive';
  end if;
  if (select count(*) from public.shipment_documents d where d.shipment_id = p_shipment_id
      and d.processing_status in ('complete', 'manual_entry')) <> 3
     or (select count(distinct d.document_type) from public.shipment_documents d where d.shipment_id = p_shipment_id
      and d.processing_status in ('complete', 'manual_entry')) <> 3 then
    raise exception 'Review all three document types before submitting';
  end if;
  select count(*), coalesce(sum(line_total), 0) into item_count, item_sum
    from public.shipment_items where shipment_id = p_shipment_id;
  if item_count = 0 then raise exception 'At least one confirmed line item is required'; end if;
  if exists (select 1 from public.shipment_items i where i.shipment_id = p_shipment_id
    and (btrim(i.description) = '' or i.hsn_code is null or btrim(i.hsn_code) = ''
      or i.quantity is null or i.quantity <= 0 or i.unit_price is null or i.line_total is null
      or abs(i.line_total - round(i.quantity * i.unit_price, 2)) > 0.01)) then
    raise exception 'Complete each line item description, HSN, quantity and unit price';
  end if;
  if btrim(s.supplier_name) = '' or btrim(coalesce(s.invoice_number, '')) = ''
     or s.currency is null or btrim(coalesce(s.incoterm, '')) = '' then
    raise exception 'Confirm supplier, invoice number, currency and Incoterm';
  end if;
  if s.invoice_total is null or abs(s.invoice_total - item_sum) > 0.01 then
    raise exception 'Invoice total does not match the line item sum';
  end if;
  if exists (select 1 from unnest(s.review_required_fields) as required(field)
    where not (required.field = any(s.confirmed_fields))) then
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
  update public.shipments set status = 'ready_for_approval', submitted_by = (select auth.uid()), submitted_at = now()
    where id = p_shipment_id;
  insert into public.shipment_approval_events (shipment_id, executive_id, actor_id, decision)
    values (p_shipment_id, (select auth.uid()), (select auth.uid()), 'submitted');
end;
$$;

create or replace function public.manager_decide_shipment(
  p_shipment_id uuid, p_decision text, p_note text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  s public.shipments%rowtype;
  clean_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if public.current_user_role() is distinct from 'manager'::public.app_role then
    raise exception 'Only an active manager can decide a shipment';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected', 'returned_for_correction') then
    raise exception 'Choose approve, reject, or return for correction';
  end if;
  if p_decision in ('rejected', 'returned_for_correction') and clean_note is null then
    raise exception 'Add a reason before rejecting or returning this shipment';
  end if;
  select * into s from public.shipments where id = p_shipment_id for update;
  if not found or s.status <> 'ready_for_approval' or s.submitted_by = (select auth.uid()) then
    raise exception 'This shipment is not awaiting review by this manager';
  end if;
  insert into public.shipment_approval_events (shipment_id, executive_id, actor_id, decision, note)
    values (p_shipment_id, s.submitted_by, (select auth.uid()), p_decision, clean_note);
  if p_decision = 'approved' then
    update public.shipments set status = 'approved', approved_by = (select auth.uid()), approved_at = now()
      where id = p_shipment_id;
  else
    update public.shipments set status = 'needs_review', approved_by = null, approved_at = null
      where id = p_shipment_id;
  end if;
end;
$$;

create or replace function public.approve_shipment(p_shipment_id uuid)
returns void language sql security definer set search_path = '' as $$
  select public.manager_decide_shipment(p_shipment_id, 'approved', null)
$$;

create or replace function public.mark_document_manual_entry(p_document_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.current_user_role() is distinct from 'executive'::public.app_role then
    raise exception 'Only an active executive can mark a document for manual entry';
  end if;
  update public.shipment_documents d set processing_status = 'manual_entry', failure_reason = null
    from public.shipments s
    where d.id = p_document_id and s.id = d.shipment_id
      and s.created_by = (select auth.uid()) and s.status in ('in_progress', 'needs_review');
  if not found then raise exception 'Document is not available for this executive to review'; end if;
end;
$$;

revoke execute on function public.submit_shipment_for_approval(uuid) from public, anon;
revoke execute on function public.approve_shipment(uuid) from public, anon;
revoke execute on function public.manager_decide_shipment(uuid, text, text) from public, anon;
revoke execute on function public.mark_document_manual_entry(uuid) from public, anon;
grant execute on function public.submit_shipment_for_approval(uuid) to authenticated;
grant execute on function public.approve_shipment(uuid) to authenticated;
grant execute on function public.manager_decide_shipment(uuid, text, text) to authenticated;
grant execute on function public.mark_document_manual_entry(uuid) to authenticated;

