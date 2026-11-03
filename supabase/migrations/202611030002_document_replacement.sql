-- Allow executives to remove an incorrect upload before adding its replacement.
grant delete on public.shipment_documents to authenticated;

create policy documents_delete on public.shipment_documents for delete to authenticated
  using (
    (select public.current_user_role()) = 'executive'::public.app_role
    and exists (
      select 1 from public.shipments s
      where s.id = shipment_id and s.status in ('in_progress', 'needs_review')
    )
  );

create or replace function public.audit_document_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.shipment_audit (
    shipment_id, actor_id, entity, entity_id, field_name, old_value, new_value
  ) values (
    old.shipment_id, auth.uid(), 'shipment_documents', old.id, 'document_removed',
    jsonb_build_object('document_type', old.document_type, 'original_filename', old.original_filename), null
  );

  if old.document_type = 'invoice' then
    update public.shipments set
      supplier_name = '', supplier_country = null, invoice_number = null, invoice_date = null,
      currency = null, incoterm = null, invoice_total = null, package_count = null,
      package_type = null, gross_weight_kg = null, net_weight_kg = null, container_numbers = '{}',
      confirmed_fields = '{}',
      review_required_fields = array(
        select field from unnest(review_required_fields) as field
        where field not like 'invoice.%'
      )
    where id = old.shipment_id;
    delete from public.shipment_items where shipment_id = old.shipment_id;
  else
    update public.shipments set
      confirmed_fields = array(
        select field from unnest(confirmed_fields) as field
        where field not like old.document_type::text || '.%'
      )
    where id = old.shipment_id;
  end if;

  return old;
end;
$$;

create trigger shipment_documents_audit_delete
after delete on public.shipment_documents
for each row execute function public.audit_document_delete();
