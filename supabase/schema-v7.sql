-- schema-v7.sql
-- Aplicar depois de schema.sql, schema-v2.sql, schema-v3.sql, schema-v4.sql, schema-v5.sql e schema-v6.sql.
-- Corrige: força bruta no PIN (login e liderança), PIN usado como senha do Supabase Auth
-- e autorização de liderança enviando chapa + PIN a cada ação.

-- 1) Tabelas internas. Ninguém lê nem grava direto: só as funções SECURITY DEFINER.
create table if not exists public.tentativas_autenticacao (
  chave text primary key,
  falhas integer not null default 0,
  bloqueado_ate timestamptz,
  atualizado_em timestamptz not null default now()
);

create table if not exists public.tokens_autorizacao (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id),
  solicitante_id uuid not null references public.operadores(id),
  autorizador_id uuid not null references public.operadores(id),
  acao text not null,
  expira_em timestamptz not null,
  usado_em timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.operador_segredos (
  operador_id uuid primary key references public.operadores(id) on delete cascade,
  senha_auth text not null
);

alter table public.tentativas_autenticacao enable row level security;
alter table public.tokens_autorizacao enable row level security;
alter table public.operador_segredos enable row level security;
revoke all on public.tentativas_autenticacao, public.tokens_autorizacao, public.operador_segredos from public, anon, authenticated;

-- 2) Contadores de falha
create or replace function public.registrar_falha(p_chave text, p_max integer, p_bloqueio interval)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into tentativas_autenticacao (chave, falhas) values (p_chave, 1)
  on conflict (chave) do update set
    falhas = case when tentativas_autenticacao.bloqueado_ate is not null and tentativas_autenticacao.bloqueado_ate <= now()
                  then 1 else tentativas_autenticacao.falhas + 1 end,
    bloqueado_ate = case when tentativas_autenticacao.bloqueado_ate is not null and tentativas_autenticacao.bloqueado_ate <= now()
                         then null else tentativas_autenticacao.bloqueado_ate end,
    atualizado_em = now();
  update tentativas_autenticacao set bloqueado_ate = now() + p_bloqueio
  where chave = p_chave and falhas >= p_max and bloqueado_ate is null;
end $$;

create or replace function public.bloqueio_ativo(p_chave text)
returns timestamptz language sql stable security definer set search_path = public as $$
  select bloqueado_ate from tentativas_autenticacao where chave = p_chave and bloqueado_ate > now()
$$;

create or replace function public.zerar_falhas(p_chave text)
returns void language sql security definer set search_path = public as $$
  delete from tentativas_autenticacao where chave = p_chave
$$;

create or replace function public.chapa_de(p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select chapa from operadores where id = p_id
$$;

revoke all on function public.registrar_falha(text, integer, interval), public.bloqueio_ativo(text),
  public.zerar_falhas(text), public.chapa_de(uuid) from public, anon, authenticated;

-- 3) Login: devolve a senha do Supabase Auth (aleatória) somente depois de conferir o PIN.
-- Não usa raise: assim o contador de falhas fica gravado.
drop function if exists public.login_chapa(text, text);
drop function if exists public.login_chapa(text, text, text);

create function public.login_chapa(p_codigo_acesso text, p_chapa text, p_pin text)
returns table (id uuid, loja_id uuid, auth_email text, auth_senha text, cargo text, nome text)
language plpgsql security definer set search_path = public, extensions as $$
declare
  chave_chapa text := 'login:' || upper(coalesce(p_codigo_acesso, '')) || ':' || lower(coalesce(p_chapa, ''));
  chave_ip text;
  ip text;
  r record;
begin
  -- IP entra no contador só quando o servidor informa o cliente; sem IP, um balde comum bloquearia todos.
  begin
    ip := nullif(trim(split_part((current_setting('request.headers', true)::json) ->> 'x-forwarded-for', ',', 1)), '');
  exception when others then
    ip := null;
  end;
  chave_ip := case when ip is null then null else 'loginip:' || ip end;

  if bloqueio_ativo(chave_chapa) is not null or (chave_ip is not null and bloqueio_ativo(chave_ip) is not null) then
    return;
  end if;

  if p_codigo_acesso !~ '^[A-Fa-f0-9]{12}$' or p_chapa !~ '^[A-Za-z0-9-]{1,20}$' or p_pin !~ '^\d{6}$' then
    if chave_ip is not null then perform registrar_falha(chave_ip, 50, interval '15 minutes'); end if;
    return;
  end if;

  select o.id as oid, o.loja_id as lid, o.auth_email as em, s.senha_auth as sn, o.cargo as cg, o.nome as nm
    into r
  from operadores o
  join lojas l on l.id = o.loja_id
  join operador_segredos s on s.operador_id = o.id
  where l.codigo_acesso = upper(p_codigo_acesso)
    and o.chapa = p_chapa
    and o.ativo
    and o.pin_hash = crypt(p_pin, o.pin_hash)
  limit 1;

  if not found then
    perform registrar_falha(chave_chapa, 5, interval '10 minutes');
    if chave_ip is not null then perform registrar_falha(chave_ip, 50, interval '15 minutes'); end if;
    return;
  end if;

  perform zerar_falhas(chave_chapa);
  return query select r.oid, r.lid, r.em, r.sn, r.cg, r.nm;
end $$;

grant execute on function public.login_chapa(text, text, text) to anon, authenticated;

-- 4) Liderança em duas etapas.
-- validar_lideranca confere chapa + PIN com contador e devolve um token de uso único (90 s).
drop function if exists public.autorizar_lideranca(text, text);

create or replace function public.validar_lideranca(p_chapa text, p_pin text, p_acao text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := current_operator_id();
  store uuid := current_store_id();
  boss uuid;
  k_op text;
  k_chapa text;
  ate timestamptz;
  tok uuid;
begin
  if auth.uid() is null or me is null or store is null then
    return jsonb_build_object('ok', false, 'erro', 'Sessão inválida. Entre novamente.');
  end if;
  if p_acao not in ('cancelamento_item','estorno_venda','desconto_manual','abertura_caixa','sangria','fechamento_z') then
    return jsonb_build_object('ok', false, 'erro', 'Ação inválida.');
  end if;

  k_op := 'op:' || me;
  k_chapa := 'lid:' || store || ':' || lower(coalesce(p_chapa, ''));
  ate := coalesce(bloqueio_ativo(k_op), bloqueio_ativo(k_chapa));
  if ate is not null then
    return jsonb_build_object('ok', false, 'erro', 'Autorização bloqueada por excesso de tentativas. Tente novamente às ' || to_char(ate at time zone 'America/Bahia', 'HH24:MI') || '.');
  end if;

  if p_chapa is null or p_pin is null or p_chapa !~ '^[A-Za-z0-9-]{1,20}$' or p_pin !~ '^\d{6}$' then
    perform registrar_falha(k_op, 5, interval '10 minutes');
    return jsonb_build_object('ok', false, 'erro', 'Chapa ou senha de liderança inválida.');
  end if;

  select id into boss from operadores
  where loja_id = store and chapa = p_chapa and ativo
    and cargo in ('lider','supervisor','gerente')
    and pin_hash = crypt(p_pin, pin_hash);

  if boss is null then
    perform registrar_falha(k_op, 5, interval '10 minutes');
    perform registrar_falha(k_chapa, 10, interval '10 minutes');
    return jsonb_build_object('ok', false, 'erro', 'Chapa ou senha de liderança inválida.');
  end if;

  perform zerar_falhas(k_op);
  perform zerar_falhas(k_chapa);
  insert into tokens_autorizacao (loja_id, solicitante_id, autorizador_id, acao, expira_em)
  values (store, me, boss, p_acao, now() + interval '90 seconds')
  returning id into tok;

  return jsonb_build_object('ok', true, 'token', tok);
end $$;

grant execute on function public.validar_lideranca(text, text, text) to authenticated;
revoke execute on function public.validar_lideranca(text, text, text) from public, anon;

-- Consumido dentro de cada ação. Se a ação falhar, a transação desfaz e o token continua válido.
create or replace function public.consumir_token(p_token uuid, p_acao text)
returns uuid language plpgsql security definer set search_path = public as $$
declare t tokens_autorizacao;
begin
  select * into t from tokens_autorizacao
  where id = p_token and acao = p_acao
    and solicitante_id = current_operator_id() and loja_id = current_store_id()
    and usado_em is null and expira_em > now()
  for update;
  if not found then
    raise exception 'Autorização da liderança inválida ou expirada. Refaça a autorização.';
  end if;
  update tokens_autorizacao set usado_em = now() where id = t.id;
  return t.autorizador_id;
end $$;

revoke all on function public.consumir_token(uuid, text) from public, anon, authenticated;

-- 5) Ações protegidas. Cada uma recebe p_token em vez de chapa + PIN.
drop function if exists public.aplicar_desconto_carrinho(uuid, text, numeric, text, text, text);
drop function if exists public.abrir_caixa(text, text, text, numeric, text);
drop function if exists public.abrir_caixa(text, text, text, numeric);
drop function if exists public.registrar_sangria(text, numeric, text, text, text);
drop function if exists public.registrar_sangria(text, numeric, text);
drop function if exists public.cancelar_item_carrinho(uuid, uuid, text, text, text);
drop function if exists public.cancelar_item_carrinho(uuid, uuid, text, text);
drop function if exists public.estornar_venda(uuid, text, text, text);
drop function if exists public.estornar_venda(uuid, text, text);
drop function if exists public.fechar_caixa_z(text, text, text, text);
drop function if exists public.fechar_caixa_z(text, text, text);

create or replace function public.aplicar_desconto_carrinho(p_carrinho_id uuid, p_tipo text, p_valor numeric, p_token uuid, p_motivo text)
returns numeric language plpgsql security definer set search_path = public as $$
declare c carrinhos_ativos; boss uuid; subtotal numeric; discount numeric;
begin
  select * into c from carrinhos_ativos where id = p_carrinho_id and loja_id = current_store_id() and status = 'aberto' for update;
  if not found then raise exception 'Carrinho indisponível'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Motivo obrigatório'; end if;
  boss := consumir_token(p_token, 'desconto_manual');

  select coalesce(sum(i.quantidade * v.preco), 0) into subtotal
  from carrinho_itens i join produto_variacoes v on v.id = i.variacao_id where i.carrinho_id = c.id;

  if p_tipo = 'percentual' then
    if p_valor is null or p_valor <= 0 or p_valor > 100 then raise exception 'Percentual deve ser entre 0 e 100'; end if;
    discount := round(subtotal * p_valor / 100, 2);
  elsif p_tipo = 'valor' then
    if p_valor is null or p_valor <= 0 or p_valor > subtotal then raise exception 'Desconto em valor inválido'; end if;
    discount := p_valor;
  else
    raise exception 'Tipo de desconto inválido';
  end if;

  update carrinhos_ativos set desconto_total = discount, updated_at = now() where id = c.id;
  insert into logs_autorizacao_lideranca (loja_id, pdv_id, operador_id, chapa_autorizador, autorizado_por, acao, motivo, valor, carrinho_id)
  values (c.loja_id, c.pdv_id, current_operator_id(), chapa_de(boss), boss, 'desconto_manual', p_motivo, discount, c.id);
  return discount;
end $$;

create or replace function public.abrir_caixa(p_pdv_codigo text, p_token uuid, p_fundo numeric, p_motivo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare store uuid := current_store_id(); terminal uuid; boss uuid; drawer uuid;
begin
  if auth.uid() is null or p_fundo is null or p_fundo < 0 or coalesce(trim(p_motivo), '') = '' then
    raise exception 'Fundo e motivo inválidos';
  end if;
  boss := consumir_token(p_token, 'abertura_caixa');
  select id into terminal from pdvs where loja_id = store and codigo = p_pdv_codigo and ativo;
  if terminal is null then raise exception 'PDV inválido'; end if;
  insert into caixas_abertos (loja_id, pdv_id, aberto_por, fundo_troco) values (store, terminal, boss, p_fundo) returning id into drawer;
  if p_fundo > 0 then
    insert into caixa_movimentos (loja_id, pdv_id, caixa_id, operador_id, tipo, valor, motivo)
    values (store, terminal, drawer, boss, 'fundo_troco', p_fundo, 'Abertura de caixa');
  end if;
  insert into logs_autorizacao_lideranca (loja_id, pdv_id, operador_id, chapa_autorizador, autorizado_por, acao, motivo, valor)
  values (store, terminal, current_operator_id(), chapa_de(boss), boss, 'abertura_caixa', p_motivo, p_fundo);
  return drawer;
end $$;

create or replace function public.registrar_sangria(p_pdv_codigo text, p_valor numeric, p_motivo text, p_token uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare store uuid := current_store_id(); terminal uuid; drawer uuid; movement uuid; boss uuid;
begin
  if auth.uid() is null or p_valor is null or p_valor <= 0 or coalesce(trim(p_motivo), '') = '' then
    raise exception 'Valor/motivo de sangria inválido';
  end if;
  boss := consumir_token(p_token, 'sangria');
  select id into terminal from pdvs where loja_id = store and codigo = p_pdv_codigo and ativo;
  select id into drawer from caixas_abertos where pdv_id = terminal and fechado_em is null for update;
  if drawer is null then raise exception 'Caixa não está aberto'; end if;
  insert into caixa_movimentos (loja_id, pdv_id, caixa_id, operador_id, tipo, valor, motivo)
  values (store, terminal, drawer, current_operator_id(), 'sangria', p_valor, p_motivo) returning id into movement;
  insert into logs_autorizacao_lideranca (loja_id, pdv_id, operador_id, chapa_autorizador, autorizado_por, acao, motivo, valor)
  values (store, terminal, current_operator_id(), chapa_de(boss), boss, 'sangria', p_motivo, p_valor);
  return movement;
end $$;

create or replace function public.cancelar_item_carrinho(p_carrinho_id uuid, p_item_id uuid, p_motivo text, p_token uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c carrinhos_ativos; boss uuid;
begin
  select * into c from carrinhos_ativos where id = p_carrinho_id and loja_id = current_store_id() and status = 'aberto' for update;
  if not found then raise exception 'Carrinho indisponível'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Motivo obrigatório'; end if;
  boss := consumir_token(p_token, 'cancelamento_item');
  if not exists (select 1 from carrinho_itens where id = p_item_id and carrinho_id = c.id) then
    raise exception 'Item não encontrado';
  end if;
  insert into auditoria_cancelamentos (loja_id, carrinho_id, item_id, operador_id, autorizado_por, tipo)
  values (c.loja_id, c.id, p_item_id, current_operator_id(), boss, 'item');
  insert into logs_autorizacao_lideranca (loja_id, pdv_id, operador_id, chapa_autorizador, autorizado_por, acao, motivo, carrinho_id)
  values (c.loja_id, c.pdv_id, current_operator_id(), chapa_de(boss), boss, 'cancelamento_item', p_motivo, c.id);
  delete from carrinho_itens where id = p_item_id and carrinho_id = c.id;
end $$;

create or replace function public.estornar_venda(p_venda_id uuid, p_motivo text, p_token uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s vendas; boss uuid;
begin
  select * into s from vendas where id = p_venda_id and loja_id = current_store_id() for update;
  if not found then raise exception 'Venda não encontrada'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Motivo obrigatório'; end if;
  if s.status = 'estornada' then raise exception 'Venda já estornada'; end if;
  boss := consumir_token(p_token, 'estorno_venda');
  update produto_variacoes v set estoque = v.estoque + i.quantidade from venda_itens i
  where i.venda_id = s.id and i.variacao_id = v.id;
  insert into auditoria_cancelamentos (loja_id, venda_id, operador_id, autorizado_por, tipo)
  values (s.loja_id, s.id, current_operator_id(), boss, 'venda');
  insert into logs_autorizacao_lideranca (loja_id, pdv_id, operador_id, chapa_autorizador, autorizado_por, acao, motivo, valor, venda_id)
  values (s.loja_id, s.pdv_id, current_operator_id(), chapa_de(boss), boss, 'estorno_venda', p_motivo, s.total, s.id);
  update vendas set status = 'estornada' where id = s.id;
end $$;

-- Relatório Z: mesmo conteúdo da v3, agora com token.
create or replace function public.fechar_caixa_z(p_pdv_codigo text,p_motivo text,p_token uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare boss uuid; terminal uuid; store uuid:=current_store_id(); closeid uuid; start_at timestamptz; end_at timestamptz:=now(); report jsonb;
begin
 if coalesce(trim(p_motivo),'')='' then raise exception 'Motivo obrigatório'; end if; boss:=consumir_token(p_token,'fechamento_z');
 select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo and ativo; if terminal is null then raise exception 'PDV inválido'; end if;
 select coalesce(max(periodo_fim),date_trunc('day',now())) into start_at from fechamentos_z where pdv_id=terminal;
 select jsonb_build_object('pdv',p_pdv_codigo,'periodo_inicio',start_at,'periodo_fim',end_at,
  'total_vendas',coalesce(sum(v.total) filter(where v.status='concluida'),0),'total_trocas',coalesce(sum(v.trocas_total) filter(where v.status='concluida'),0),'estornos',coalesce(sum(v.total) filter(where v.status='estornada'),0),
  'fundo_troco',coalesce((select sum(valor) from caixa_movimentos where pdv_id=terminal and tipo='fundo_troco' and created_at>start_at and created_at<=end_at),0),
  'sangrias',coalesce((select sum(valor) from caixa_movimentos where pdv_id=terminal and tipo='sangria' and created_at>start_at and created_at<=end_at),0),
  'por_pagamento',coalesce((select jsonb_object_agg(forma_pagamento,valor) from(select forma_pagamento,sum(total) valor from vendas where pdv_id=terminal and status='concluida' and created_at>start_at and created_at<=end_at group by forma_pagamento) a),'{}'::jsonb),
  'por_operador',coalesce((select jsonb_agg(jsonb_build_object('chapa',a.chapa_snapshot,'operador',o.nome,'total',a.valor,'vendas',a.qtd,'celular',a.celular,'balcao',a.balcao)) from(select operador_id,chapa_snapshot,sum(total) filter(where status='concluida') valor,count(*) filter(where status='concluida') qtd,count(*) filter(where origem='celular' and status='concluida') celular,count(*) filter(where origem='caixa' and status='concluida') balcao from vendas where pdv_id=terminal and created_at>start_at and created_at<=end_at group by operador_id,chapa_snapshot) a join operadores o on o.id=a.operador_id),'[]'::jsonb),
  'pos',coalesce((select jsonb_agg(jsonb_build_object('marca',p.marca,'nsu',p.nsu,'data',p.data_transacao,'valor',p.valor)) from venda_pagamentos_pos p join vendas x on x.id=p.venda_id where x.pdv_id=terminal and x.status='concluida' and x.created_at>start_at and x.created_at<=end_at),'[]'::jsonb),
  'trocas',coalesce((select jsonb_agg(jsonb_build_object('nota',t.numero_nota_fiscal,'valor',t.valor_credito,'quantidade',t.quantidade)) from trocas t join vendas x on x.id=t.venda_id where x.pdv_id=terminal and x.created_at>start_at and x.created_at<=end_at),'[]'::jsonb),
  'autorizacoes',coalesce((select jsonb_agg(jsonb_build_object('acao',acao,'chapa',chapa_autorizador,'motivo',motivo,'valor',valor,'horario',created_at)) from logs_autorizacao_lideranca where pdv_id=terminal and created_at>start_at and created_at<=end_at),'[]'::jsonb)) into report
 from vendas v where v.pdv_id=terminal and v.created_at>start_at and v.created_at<=end_at;
 insert into logs_autorizacao_lideranca(loja_id,pdv_id,operador_id,chapa_autorizador,autorizado_por,acao,motivo,created_at) values(store,terminal,current_operator_id(),chapa_de(boss),boss,'fechamento_z',p_motivo,end_at);
 report:=report||jsonb_build_object('autorizacoes',coalesce((select jsonb_agg(jsonb_build_object('acao',acao,'chapa',chapa_autorizador,'motivo',motivo,'valor',valor,'horario',created_at) order by created_at) from logs_autorizacao_lideranca where pdv_id=terminal and created_at>start_at and created_at<=end_at),'[]'::jsonb));
 insert into fechamentos_z(loja_id,pdv_id,operador_id,periodo_inicio,periodo_fim,relatorio,fundo_troco,sangrias) values(store,terminal,boss,start_at,end_at,report,coalesce((report->>'fundo_troco')::numeric,0),coalesce((report->>'sangrias')::numeric,0)) returning id into closeid;
 update caixas_abertos set fechado_em=end_at,fechamento_id=closeid where pdv_id=terminal and fechado_em is null;
 return jsonb_build_object('id',closeid,'relatorio',report);
end $$;
grant execute on function public.fechar_caixa_z(text,text,uuid) to authenticated;
revoke execute on function public.fechar_caixa_z(text,text,uuid) from public,anon;

-- 6) Permissões das ações protegidas
grant execute on function public.aplicar_desconto_carrinho(uuid, text, numeric, uuid, text) to authenticated;
grant execute on function public.abrir_caixa(text, uuid, numeric, text) to authenticated;
grant execute on function public.registrar_sangria(text, numeric, text, uuid) to authenticated;
grant execute on function public.cancelar_item_carrinho(uuid, uuid, text, uuid) to authenticated;
grant execute on function public.estornar_venda(uuid, text, uuid) to authenticated;
grant execute on function public.fechar_caixa_z(text, text, uuid) to authenticated;
revoke execute on function public.aplicar_desconto_carrinho(uuid, text, numeric, uuid, text) from public, anon;
revoke execute on function public.abrir_caixa(text, uuid, numeric, text) from public, anon;
revoke execute on function public.registrar_sangria(text, numeric, text, uuid) from public, anon;
revoke execute on function public.cancelar_item_carrinho(uuid, uuid, text, uuid) from public, anon;
revoke execute on function public.estornar_venda(uuid, text, uuid) from public, anon;
revoke execute on function public.fechar_caixa_z(text, text, uuid) from public, anon;

-- 7) Provisionamento: a senha do Supabase Auth é aleatória e separada do PIN.
drop function if exists public.admin_provisionar_loja(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, uuid);

create or replace function public.admin_provisionar_loja(
  p_loja_id uuid, p_operador_id uuid, p_nome_fantasia text, p_cnpj text, p_endereco text, p_telefone text,
  p_pdv_codigo text, p_pdv_nome text, p_gerente_nome text, p_gerente_cpf text, p_gerente_chapa text,
  p_gerente_auth_email text, p_gerente_pin text, p_gerente_senha_auth text, p_auth_user_id uuid
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Ação administrativa não autorizada'; end if;
  if p_loja_id is null or p_operador_id is null or p_auth_user_id is null then raise exception 'Identificadores inválidos'; end if;
  if coalesce(trim(p_nome_fantasia), '') = '' or p_cnpj !~ '^\d{14}$' then raise exception 'Informe o nome da loja e um CNPJ com 14 dígitos'; end if;
  if coalesce(trim(p_pdv_codigo), '') = '' or coalesce(trim(p_pdv_nome), '') = '' then raise exception 'Informe o código e o nome do primeiro PDV'; end if;
  if coalesce(trim(p_gerente_nome), '') = '' or p_gerente_cpf !~ '^\d{11}$' then raise exception 'Informe o nome do gerente e um CPF com 11 dígitos'; end if;
  if p_gerente_chapa !~ '^[A-Za-z0-9-]{1,20}$' or p_gerente_pin !~ '^\d{6}$' then raise exception 'Chapa ou PIN inválido'; end if;
  if p_gerente_senha_auth is null or length(p_gerente_senha_auth) < 32 then raise exception 'Senha de acesso insuficiente'; end if;

  insert into public.lojas (id, codigo_acesso, nome_fantasia, cnpj, endereco, telefone)
  values (p_loja_id, upper(substr(replace(p_loja_id::text, '-', ''), 1, 12)), trim(p_nome_fantasia), p_cnpj, coalesce(trim(p_endereco), ''), coalesce(trim(p_telefone), ''));

  insert into public.pdvs (loja_id, codigo, nome) values (p_loja_id, trim(p_pdv_codigo), trim(p_pdv_nome));

  insert into public.operadores (id, loja_id, auth_user_id, cpf, auth_email, pin_hash, nome, ativo, chapa, cargo)
  values (p_operador_id, p_loja_id, p_auth_user_id, p_gerente_cpf, p_gerente_auth_email,
          crypt(p_gerente_pin, gen_salt('bf')), trim(p_gerente_nome), true, trim(p_gerente_chapa), 'gerente');

  insert into public.operador_segredos (operador_id, senha_auth) values (p_operador_id, p_gerente_senha_auth);

  return jsonb_build_object(
    'loja_id', p_loja_id,
    'operador_id', p_operador_id,
    'codigo_acesso', (select l.codigo_acesso from public.lojas l where l.id = p_loja_id)
  );
end $$;

revoke all on function public.admin_provisionar_loja(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.admin_provisionar_loja(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, text, uuid) to service_role;

-- 8) Clientes (LGPD): ninguém lista a base da loja. Consulta só por CPF exato, dentro da própria loja.
drop policy if exists cliente_read on public.clientes;
revoke select on public.clientes from authenticated;

create or replace function public.buscar_cliente(p_cpf text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is null or current_store_id() is null or p_cpf is null or p_cpf !~ '^\d{11}$' then
    return null;
  end if;
  select jsonb_build_object('nome', nome, 'email', coalesce(email, '')) into r
  from clientes where loja_id = current_store_id() and cpf = p_cpf;
  return r;
end $$;

grant execute on function public.buscar_cliente(text) to authenticated;
revoke execute on function public.buscar_cliente(text) from public, anon;
