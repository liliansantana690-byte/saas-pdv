-- Endurecimento de segurança. Aplicar depois de schema.sql, schema-v2.sql e schema-v3.sql.
-- As assinaturas das RPCs chamadas pelo front-end permanecem iguais.

-- Bloqueia gravações diretas no PostgREST. Mutations passam por RPC SECURITY DEFINER;
-- a única gravação direta autorizada é criar um carrinho próprio.
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant insert(loja_id, operador_id, origem, pdv_id) on public.carrinhos_ativos to authenticated;

drop policy if exists produto_access on public.produtos;
drop policy if exists variacao_access on public.produto_variacoes;
drop policy if exists cliente_access on public.clientes;
drop policy if exists carrinho_update on public.carrinhos_ativos;
drop policy if exists carrinho_item_insert on public.carrinho_itens;
drop policy if exists carrinho_item_update on public.carrinho_itens;
drop policy if exists carrinho_item_delete on public.carrinho_itens;
create policy produto_read on public.produtos for select to authenticated using(loja_id=current_store_id());
create policy variacao_read on public.produto_variacoes for select to authenticated using(loja_id=current_store_id());
create policy cliente_read on public.clientes for select to authenticated using(loja_id=current_store_id());

revoke execute on function public.current_operator_id() from anon;
revoke execute on function public.current_store_id() from anon;
revoke execute on function public.adicionar_item_carrinho(uuid,uuid,integer) from public,anon;
revoke execute on function public.adicionar_troca_carrinho(uuid,text,text,numeric,integer) from public,anon;
revoke execute on function public.registrar_entrada_estoque(jsonb) from public,anon;
revoke execute on function public.auditoria_vendas(text,text,text,date) from public,anon;

create table if not exists public.movimentos_estoque(
 id uuid primary key default gen_random_uuid(), loja_id uuid not null references public.lojas(id),
 variacao_id uuid not null references public.produto_variacoes(id), operador_id uuid not null references public.operadores(id),
 tipo text not null check(tipo in('entrada')), quantidade integer not null check(quantidade>0), created_at timestamptz not null default now()
);
create index if not exists mov_estoque_loja_data_idx on public.movimentos_estoque(loja_id,created_at desc);
alter table public.movimentos_estoque enable row level security;
create policy mov_estoque_read on public.movimentos_estoque for select to authenticated using(loja_id=current_store_id());
revoke all on public.movimentos_estoque from anon;
revoke insert,update,delete,truncate on public.movimentos_estoque from authenticated;
grant select on public.movimentos_estoque to authenticated;

create or replace function public.registrar_entrada_estoque(p_itens jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare item jsonb; code text; qty integer; changed integer:=0; store uuid:=current_store_id(); me uuid:=current_operator_id(); vid uuid;
begin
 if auth.uid() is null or store is null or jsonb_typeof(p_itens)<>'array' then raise exception 'Entrada inválida'; end if;
 if not exists(select 1 from public.operadores where id=me and cargo in('lider','supervisor','gerente')) then raise exception 'Entrada de estoque exige cargo de liderança'; end if;
 for item in select value from jsonb_array_elements(p_itens) loop
  code:=item->>'codigo'; qty:=(item->>'quantidade')::integer;
  if qty is null or qty<1 or qty>100000 then raise exception 'Quantidade inválida'; end if;
  select id into vid from public.produto_variacoes where loja_id=store and (codigo_barras=code or sku=code) and ativo for update;
  if vid is null then raise exception 'Código não localizado: %',code; end if;
  update public.produto_variacoes set estoque=estoque+qty where id=vid;
  insert into public.movimentos_estoque(loja_id,variacao_id,operador_id,tipo,quantidade) values(store,vid,me,'entrada',qty);
  changed:=changed+1; vid:=null;
 end loop;
 return jsonb_build_object('atualizados',changed);
end $$;
revoke execute on function public.registrar_entrada_estoque(jsonb) from public,anon;
grant execute on function public.registrar_entrada_estoque(jsonb) to authenticated;

-- Mantém assinatura pública do front-end, mas restringe consultas do portal.
alter function public.auditoria_vendas(text,text,text,date) rename to auditoria_vendas_interna;
revoke all on function public.auditoria_vendas_interna(text,text,text,date) from public,anon,authenticated;
create or replace function public.auditoria_vendas(p_pdv_codigo text,p_chapa text,p_periodo text,p_mes date default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or not exists(select 1 from public.operadores where id=public.current_operator_id() and cargo in('supervisor','gerente')) then raise exception 'Acesso restrito a supervisor ou gerente'; end if;
 return public.auditoria_vendas_interna(p_pdv_codigo,p_chapa,p_periodo,p_mes);
end $$;
revoke execute on function public.auditoria_vendas(text,text,text,date) from public,anon;
grant execute on function public.auditoria_vendas(text,text,text,date) to authenticated;

-- O crédito de troca não pode exceder o preço da quantidade devolvida.
alter function public.adicionar_troca_carrinho(uuid,text,text,numeric,integer) rename to adicionar_troca_carrinho_interna;
revoke all on function public.adicionar_troca_carrinho_interna(uuid,text,text,numeric,integer) from public,anon,authenticated;
create or replace function public.adicionar_troca_carrinho(p_carrinho_id uuid,p_codigo text,p_nota_fiscal text,p_valor numeric,p_quantidade integer default 1)
returns uuid language plpgsql security definer set search_path=public as $$
declare price numeric;
begin
 if auth.uid() is null or p_quantidade<1 or p_valor<=0 then raise exception 'Dados da troca inválidos'; end if;
 select preco into price from public.produto_variacoes where loja_id=public.current_store_id() and ativo and (codigo_barras=p_codigo or sku=p_codigo);
 if price is null then raise exception 'Produto devolvido não localizado'; end if;
 if p_valor>price*p_quantidade then raise exception 'Crédito da troca maior que o valor do item devolvido'; end if;
 return public.adicionar_troca_carrinho_interna(p_carrinho_id,p_codigo,p_nota_fiscal,p_valor,p_quantidade);
end $$;
revoke execute on function public.adicionar_troca_carrinho(uuid,text,text,numeric,integer) from public,anon;
grant execute on function public.adicionar_troca_carrinho(uuid,text,text,numeric,integer) to authenticated;

do $$ begin
 alter publication supabase_realtime add table public.carrinho_itens;
exception when duplicate_object then null; when undefined_object then null;
end $$;
