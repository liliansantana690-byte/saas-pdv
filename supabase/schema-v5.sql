-- Identidade visual configurável por loja. Aplicar após schema-v4.sql.
alter table public.lojas add column if not exists logo_url text;
alter table public.lojas add column if not exists cor_primaria text not null default '#0f172a';
alter table public.lojas add column if not exists cor_secundaria text not null default '#334155';

alter table public.lojas drop constraint if exists lojas_logo_url_https_check;
alter table public.lojas add constraint lojas_logo_url_https_check check(logo_url is null or logo_url ~* '^https://');
alter table public.lojas drop constraint if exists lojas_cor_primaria_hex_check;
alter table public.lojas add constraint lojas_cor_primaria_hex_check check(cor_primaria ~ '^#[0-9A-Fa-f]{6}$');
alter table public.lojas drop constraint if exists lojas_cor_secundaria_hex_check;
alter table public.lojas add constraint lojas_cor_secundaria_hex_check check(cor_secundaria ~ '^#[0-9A-Fa-f]{6}$');

create or replace function public.minha_identidade_loja()
returns table(loja_id uuid,nome_fantasia text,logo_url text,cor_primaria text,cor_secundaria text)
language sql stable security definer set search_path=public as $$
 select l.id,l.nome_fantasia,l.logo_url,l.cor_primaria,l.cor_secundaria
 from public.lojas l join public.operadores o on o.loja_id=l.id
 where o.auth_user_id=auth.uid() and o.ativo
 limit 1
$$;
revoke all on function public.minha_identidade_loja() from public,anon;
grant execute on function public.minha_identidade_loja() to authenticated;

create or replace function public.atualizar_identidade_loja(p_nome_fantasia text,p_logo_url text,p_cor_primaria text,p_cor_secundaria text)
returns void language plpgsql security definer set search_path=public as $$
declare store uuid:=public.current_store_id();
begin
 if auth.uid() is null or store is null then raise exception 'Sessão inválida'; end if;
 if not exists(select 1 from public.operadores where auth_user_id=auth.uid() and ativo and cargo in('supervisor','gerente')) then raise exception 'Somente supervisor ou gerente pode alterar a identidade da loja'; end if;
 if coalesce(trim(p_nome_fantasia),'')='' then raise exception 'Informe o nome da loja'; end if;
 if p_logo_url is not null and p_logo_url !~* '^https://' then raise exception 'O endereço do logo precisa começar com https://'; end if;
 if p_cor_primaria !~ '^#[0-9A-Fa-f]{6}$' or p_cor_secundaria !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Use cores no formato hexadecimal #RRGGBB'; end if;
 update public.lojas set nome_fantasia=trim(p_nome_fantasia),logo_url=nullif(trim(p_logo_url),''),cor_primaria=p_cor_primaria,cor_secundaria=p_cor_secundaria where id=store;
 if not found then raise exception 'Loja não encontrada'; end if;
end $$;
revoke all on function public.atualizar_identidade_loja(text,text,text,text) from public,anon;
grant execute on function public.atualizar_identidade_loja(text,text,text,text) to authenticated;

do $$ begin
 alter publication supabase_realtime add table public.lojas;
exception when duplicate_object then null; when undefined_object then null;
end $$;
