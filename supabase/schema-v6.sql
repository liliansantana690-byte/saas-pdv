-- Cadastro administrativo de uma nova loja, seu primeiro PDV e gerente.
-- Aplicar depois de schema.sql e schema-v2.sql até schema-v5.sql.
-- A RPC fica restrita à chave secreta do servidor (role service_role).

alter table public.lojas add column if not exists codigo_acesso text;
update public.lojas
set codigo_acesso = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
where codigo_acesso is null or codigo_acesso = '';
alter table public.lojas alter column codigo_acesso set not null;
create unique index if not exists lojas_codigo_acesso_uidx on public.lojas(codigo_acesso);

-- O login de chapa precisa identificar a loja antes de procurar o operador.
-- A versão antiga sem código de loja fica indisponível para clientes.
revoke execute on function public.login_chapa(text,text) from public, anon, authenticated;
create or replace function public.login_chapa(p_codigo_acesso text, p_chapa text, p_pin text)
returns table(id uuid, loja_id uuid, auth_email text, cargo text, nome text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if p_codigo_acesso !~ '^[A-Fa-f0-9]{12}$' or p_chapa !~ '^[A-Za-z0-9-]{1,20}$' or p_pin !~ '^\d{6}$' then
    return;
  end if;

  return query
  select o.id, o.loja_id, o.auth_email, o.cargo, o.nome
  from public.operadores o
  join public.lojas l on l.id = o.loja_id
  where l.codigo_acesso = upper(p_codigo_acesso)
    and o.chapa = p_chapa
    and o.ativo
    and o.pin_hash = crypt(p_pin, o.pin_hash)
  limit 1;
end;
$$;
grant execute on function public.login_chapa(text,text,text) to anon, authenticated;

create or replace function public.admin_provisionar_loja(
  p_loja_id uuid,
  p_operador_id uuid,
  p_nome_fantasia text,
  p_cnpj text,
  p_endereco text,
  p_telefone text,
  p_pdv_codigo text,
  p_pdv_nome text,
  p_gerente_nome text,
  p_gerente_cpf text,
  p_gerente_chapa text,
  p_gerente_auth_email text,
  p_gerente_pin text,
  p_auth_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Ação administrativa não autorizada';
  end if;

  if p_loja_id is null or p_operador_id is null or p_auth_user_id is null then
    raise exception 'Identificadores inválidos';
  end if;
  if coalesce(trim(p_nome_fantasia), '') = '' or p_cnpj !~ '^\d{14}$' then
    raise exception 'Informe o nome da loja e um CNPJ com 14 dígitos';
  end if;
  if coalesce(trim(p_pdv_codigo), '') = '' or coalesce(trim(p_pdv_nome), '') = '' then
    raise exception 'Informe o código e o nome do primeiro PDV';
  end if;
  if coalesce(trim(p_gerente_nome), '') = '' or p_gerente_cpf !~ '^\d{11}$' then
    raise exception 'Informe o nome do gerente e um CPF com 11 dígitos';
  end if;
  if p_gerente_chapa !~ '^[A-Za-z0-9-]{1,20}$' or p_gerente_pin !~ '^\d{6}$' then
    raise exception 'Chapa ou PIN inválido';
  end if;

  insert into public.lojas(id, codigo_acesso, nome_fantasia, cnpj, endereco, telefone)
  values (p_loja_id, upper(substr(replace(p_loja_id::text, '-', ''), 1, 12)), trim(p_nome_fantasia), p_cnpj, coalesce(trim(p_endereco), ''), coalesce(trim(p_telefone), ''));

  insert into public.pdvs(loja_id, codigo, nome)
  values (p_loja_id, trim(p_pdv_codigo), trim(p_pdv_nome));

  insert into public.operadores(
    id, loja_id, auth_user_id, cpf, auth_email, pin_hash, nome, ativo, chapa, cargo
  ) values (
    p_operador_id, p_loja_id, p_auth_user_id, p_gerente_cpf, p_gerente_auth_email,
    crypt(p_gerente_pin, gen_salt('bf')), trim(p_gerente_nome), true, trim(p_gerente_chapa), 'gerente'
  );

  return jsonb_build_object(
    'loja_id', p_loja_id,
    'operador_id', p_operador_id,
    'codigo_acesso', (select l.codigo_acesso from public.lojas l where l.id = p_loja_id)
  );
end;
$$;

revoke all on function public.admin_provisionar_loja(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.admin_provisionar_loja(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,uuid) to service_role;
