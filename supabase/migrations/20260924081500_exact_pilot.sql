-- Development-only migration. Do not apply to production before review.
create table if not exists public.exact_connections (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 division bigint,
 status text not null default 'pending' check (status in ('pending','connected','disconnected','error')),
 token_secret_ref text,
 last_synced_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(owner_id, division)
);
create table if not exists public.exact_purchase_invoices (
 id uuid primary key default gen_random_uuid(),
 connection_id uuid not null references public.exact_connections(id) on delete cascade,
 exact_invoice_id text not null,
 supplier_exact_id text,
 invoice_number text,
 invoice_date date,
 currency text,
 amount_ex_vat numeric(18,4),
 vat_amount numeric(18,4),
 original_document_path text,
 raw_payload jsonb not null default '{}'::jsonb,
 imported_at timestamptz not null default now(),
 unique(connection_id, exact_invoice_id)
);
create table if not exists public.exact_purchase_lines (
 id uuid primary key default gen_random_uuid(),
 invoice_id uuid not null references public.exact_purchase_invoices(id) on delete cascade,
 exact_line_id text not null,
 description text,
 item_code text,
 quantity numeric(18,4),
 unit_price numeric(18,4),
 discount_amount numeric(18,4),
 amount_ex_vat numeric(18,4),
 raw_payload jsonb not null default '{}'::jsonb,
 unique(invoice_id, exact_line_id)
);
create index if not exists exact_invoices_connection_date_idx on public.exact_purchase_invoices(connection_id,invoice_date);
create index if not exists exact_lines_invoice_idx on public.exact_purchase_lines(invoice_id);
alter table public.exact_connections enable row level security;
alter table public.exact_purchase_invoices enable row level security;
alter table public.exact_purchase_lines enable row level security;
create policy "Owner reads own Exact connections" on public.exact_connections for select to authenticated using (owner_id = auth.uid());
create policy "Owner reads own Exact invoices" on public.exact_purchase_invoices for select to authenticated using (exists (select 1 from public.exact_connections c where c.id = connection_id and c.owner_id = auth.uid()));
create policy "Owner reads own Exact lines" on public.exact_purchase_lines for select to authenticated using (exists (select 1 from public.exact_purchase_invoices i join public.exact_connections c on c.id=i.connection_id where i.id=invoice_id and c.owner_id=auth.uid()));
-- Writes must only be performed by authenticated server-side integration code.
-- No browser insert/update/delete policies are granted.
