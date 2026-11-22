-- Aplicar depois de schema.sql para acrescentar operação por PDV, chapas, trocas e fechamento Z.
create table public.pdvs(id uuid primary key default gen_random_uuid(),loja_id uuid not null references public.lojas(id),codigo text not null,nome text not null default '',ativo boolean not null default true,created_at timestamptz not null default now(),unique(loja_id,codigo));
alter table public.operadores add column if not exists chapa text;
alter table public.operadores add column if not exists cargo text not null default 'assistente' check(cargo in('assistente','supervisor','gerente'));
create unique index if not exists operadores_loja_chapa_idx on public.operadores(loja_id,chapa) where chapa is not null;
alter table public.carrinhos_ativos add column if not exists pdv_id uuid references public.pdvs(id);
alter table public.carrinhos_ativos add column if not exists origem text not null default 'caixa' check(origem in('celular','caixa'));
alter table public.vendas add column if not exists pdv_id uuid references public.pdvs(id);
alter table public.vendas add column if not exists chapa_snapshot text;
alter table public.vendas add column if not exists origem text not null default 'caixa' check(origem in('celular','caixa'));
alter table public.vendas add column if not exists trocas_total numeric(12,2) not null default 0;
alter table public.venda_itens add column if not exists codigo_sku text;
alter table public.venda_itens add column if not exists codigo_barras text;
alter table public.venda_itens add column if not exists produto_id uuid;
create table public.venda_pagamentos_pos(id uuid primary key default gen_random_uuid(),loja_id uuid not null references public.lojas(id),venda_id uuid not null references public.vendas(id) on delete cascade,marca text not null check(marca in('visa','mastercard','elo','amex','hipercard','pix')),data_transacao date not null,nsu text not null,valor numeric(12,2) not null check(valor>0),created_at timestamptz not null default now());
create table public.trocas(id uuid primary key default gen_random_uuid(),loja_id uuid not null references public.lojas(id),carrinho_id uuid references public.carrinhos_ativos(id),venda_id uuid references public.vendas(id),variacao_id uuid not null references public.produto_variacoes(id),quantidade integer not null default 1 check(quantidade>0),numero_nota_fiscal text not null,valor_credito numeric(12,2) not null check(valor_credito>0),status text not null default 'pendente' check(status in('pendente','concluida','cancelada')),created_at timestamptz not null default now());
create table public.fechamentos_z(id uuid primary key default gen_random_uuid(),loja_id uuid not null references public.lojas(id),pdv_id uuid not null references public.pdvs(id),operador_id uuid not null references public.operadores(id),periodo_inicio timestamptz not null,periodo_fim timestamptz not null,relatorio jsonb not null,created_at timestamptz not null default now());
create table public.caixas_abertos(id uuid primary key default gen_random_uuid(),loja_id uuid not null references public.lojas(id),pdv_id uuid not null references public.pdvs(id),aberto_por uuid not null references public.operadores(id),fundo_troco numeric(12,2) not null check(fundo_troco>=0),aberto_em timestamptz not null default now(),fechado_em timestamptz,fechamento_id uuid references public.fechamentos_z(id));
create unique index if not exists one_open_register_per_pdv on public.caixas_abertos(pdv_id) where fechado_em is null;
create table public.caixa_movimentos(id uuid primary key default gen_random_uuid(),loja_id uuid not null references public.lojas(id),pdv_id uuid not null references public.pdvs(id),caixa_id uuid not null references public.caixas_abertos(id),operador_id uuid not null references public.operadores(id),tipo text not null check(tipo in('fundo_troco','sangria')),valor numeric(12,2) not null check(valor>0),motivo text not null default '',created_at timestamptz not null default now());
create table public.auditoria_cancelamentos(id uuid primary key default gen_random_uuid(),loja_id uuid not null references public.lojas(id),venda_id uuid references public.vendas(id),carrinho_id uuid references public.carrinhos_ativos(id),item_id uuid,operador_id uuid not null references public.operadores(id),autorizado_por uuid not null references public.operadores(id),tipo text not null check(tipo in('item','venda')),created_at timestamptz not null default now());
alter table public.vendas add column if not exists status text not null default 'concluida' check(status in('concluida','estornada'));
alter table public.fechamentos_z add column if not exists fundo_troco numeric(12,2) not null default 0;
alter table public.fechamentos_z add column if not exists sangrias numeric(12,2) not null default 0;
create index if not exists vendas_pdv_periodo_idx on public.vendas(pdv_id,created_at desc); create index if not exists vendas_chapa_periodo_idx on public.vendas(loja_id,chapa_snapshot,created_at desc); create index if not exists pos_venda_idx on public.venda_pagamentos_pos(venda_id); create index if not exists trocas_pdv_lookup_idx on public.trocas(loja_id,created_at desc); create index if not exists fechamento_pdv_idx on public.fechamentos_z(pdv_id,created_at desc);
alter table public.pdvs enable row level security; alter table public.venda_pagamentos_pos enable row level security; alter table public.trocas enable row level security; alter table public.fechamentos_z enable row level security;
alter table public.caixas_abertos enable row level security; alter table public.caixa_movimentos enable row level security;
alter table public.auditoria_cancelamentos enable row level security;
create policy pdvs_read on public.pdvs for select to authenticated using(loja_id=current_store_id());
create policy pos_read on public.venda_pagamentos_pos for select to authenticated using(loja_id=current_store_id());
create policy trocas_access on public.trocas for select to authenticated using(loja_id=current_store_id());
create policy fechamentos_read on public.fechamentos_z for select to authenticated using(loja_id=current_store_id());
create policy caixa_read on public.caixas_abertos for select to authenticated using(loja_id=current_store_id()); create policy caixa_moves_read on public.caixa_movimentos for select to authenticated using(loja_id=current_store_id());
create policy cancel_audit_read on public.auditoria_cancelamentos for select to authenticated using(loja_id=current_store_id());

create or replace function public.login_chapa(p_chapa text,p_pin text) returns table(id uuid,loja_id uuid,auth_email text,cargo text,nome text)
language plpgsql security definer set search_path=public,extensions as $$ begin
 if p_chapa !~ '^[A-Za-z0-9-]{1,20}$' or p_pin !~ '^\d{6}$' then return; end if;
 return query select o.id,o.loja_id,o.auth_email,o.cargo,o.nome from operadores o where o.chapa=p_chapa and o.ativo and o.pin_hash=crypt(p_pin,o.pin_hash);
end $$;
grant execute on function public.login_chapa(text,text) to anon,authenticated;

create or replace function public.adicionar_troca_carrinho(p_carrinho_id uuid,p_codigo text,p_nota_fiscal text,p_valor numeric,p_quantidade integer default 1) returns uuid
language plpgsql security definer set search_path=public as $$ declare s uuid; v uuid; result uuid; begin
 if auth.uid() is null or p_quantidade<1 or p_valor<=0 or coalesce(trim(p_nota_fiscal),'')='' then raise exception 'Dados da troca inválidos'; end if;
 select loja_id into s from carrinhos_ativos where id=p_carrinho_id and status='aberto' and loja_id=current_store_id(); if s is null then raise exception 'Carrinho indisponível'; end if;
 select id into v from produto_variacoes where loja_id=s and ativo and (codigo_barras=p_codigo or sku=p_codigo) for update; if v is null then raise exception 'Produto devolvido não localizado'; end if;
 insert into trocas(loja_id,carrinho_id,variacao_id,quantidade,numero_nota_fiscal,valor_credito) values(s,p_carrinho_id,v,p_quantidade,p_nota_fiscal,p_valor) returning id into result; update carrinhos_ativos set updated_at=now() where id=p_carrinho_id; return result;
end $$;
grant execute on function public.adicionar_troca_carrinho(uuid,text,text,numeric,integer) to authenticated;

create or replace function public.finalizar_venda_completa(p_carrinho_id uuid,p_pdv_codigo text,p_cpf text,p_nome text,p_email text,p_forma_pagamento text,p_valor_recebido numeric default null,p_pos_marca text default null,p_pos_data date default null,p_pos_nsu text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c carrinhos_ativos; store uuid; terminal uuid; customer uuid; sale uuid; gross numeric(12,2); credit numeric(12,2); due numeric(12,2); cash numeric(12,2); item record;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; store:=current_store_id();
 select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo and ativo; if terminal is null then raise exception 'PDV inválido'; end if;
 if not exists(select 1 from caixas_abertos where pdv_id=terminal and fechado_em is null) then raise exception 'Abra o caixa com fundo de troco antes de vender'; end if;
 select * into c from carrinhos_ativos where id=p_carrinho_id and status='aberto' and loja_id=store for update; if not found then raise exception 'Carrinho indisponível'; end if;
 if not exists(select 1 from carrinho_itens where carrinho_id=c.id) then raise exception 'Carrinho vazio'; end if;
 if p_cpf is not null then if p_cpf !~ '^\d{11}$' or coalesce(trim(p_nome),'')='' then raise exception 'Dados do cliente inválidos'; end if; insert into clientes(loja_id,cpf,nome,email) values(store,p_cpf,p_nome,nullif(p_email,'')) on conflict(loja_id,cpf) do update set nome=excluded.nome,email=excluded.email,updated_at=now() returning id into customer; end if;
 for item in select v.id,v.estoque,i.quantidade from produto_variacoes v join carrinho_itens i on i.variacao_id=v.id where i.carrinho_id=c.id order by v.id for update of v loop if item.estoque<item.quantidade then raise exception 'Estoque insuficiente'; end if; end loop;
 select coalesce(sum(i.quantidade*v.preco),0) into gross from carrinho_itens i join produto_variacoes v on v.id=i.variacao_id where i.carrinho_id=c.id;
 select coalesce(sum(valor_credito),0) into credit from trocas where carrinho_id=c.id and status='pendente'; if credit>gross then due:=0; else due:=gross-credit; end if;
 if p_forma_pagamento not in('debito','credito','dinheiro','pos','pix') then raise exception 'Forma de pagamento inválida'; end if;
 if p_forma_pagamento='dinheiro' then if p_valor_recebido is null or p_valor_recebido<due then raise exception 'Valor recebido insuficiente'; end if; cash:=p_valor_recebido; end if;
 if p_forma_pagamento='pos' and (p_pos_marca not in('visa','mastercard','elo','amex','hipercard','pix') or p_pos_data is null or coalesce(trim(p_pos_nsu),'')='') then raise exception 'Marca, data e NSU da POS são obrigatórios'; end if;
 insert into vendas(loja_id,operador_id,cliente_id,total,forma_pagamento,origem_carrinho_id,pdv_id,chapa_snapshot,origem,trocas_total) values(store,c.operador_id,customer,due,p_forma_pagamento,c.id,terminal,(select chapa from operadores where id=c.operador_id),c.origem,credit) returning id into sale;
 insert into venda_itens(venda_id,variacao_id,produto_nome,cor,tamanho,quantidade,preco_unitario,subtotal,codigo_sku,codigo_barras,produto_id) select sale,v.id,p.nome,v.cor,v.tamanho,i.quantidade,v.preco,i.quantidade*v.preco,v.sku,v.codigo_barras,p.id from carrinho_itens i join produto_variacoes v on v.id=i.variacao_id join produtos p on p.id=v.produto_id where i.carrinho_id=c.id;
 update produto_variacoes v set estoque=v.estoque-i.quantidade from carrinho_itens i where i.carrinho_id=c.id and i.variacao_id=v.id;
 update produto_variacoes v set estoque=v.estoque+t.quantidade from trocas t where t.carrinho_id=c.id and t.status='pendente' and t.variacao_id=v.id;
 update trocas set status='concluida',venda_id=sale where carrinho_id=c.id and status='pendente';
 if p_forma_pagamento='pos' then insert into venda_pagamentos_pos(loja_id,venda_id,marca,data_transacao,nsu,valor) values(store,sale,p_pos_marca,p_pos_data,p_pos_nsu,due); end if;
 update carrinhos_ativos set status='finalizado',pdv_id=terminal,updated_at=now() where id=c.id;
 return jsonb_build_object('loja',(select jsonb_build_object('nome_fantasia',nome_fantasia,'cnpj',cnpj,'endereco',endereco,'telefone',telefone) from lojas where id=store),'venda',jsonb_build_object('id',sale,'created_at',now(),'total',due,'forma_pagamento',p_forma_pagamento,'operador',(select nome from operadores where id=c.operador_id),'cliente_nome',(select nome from clientes where id=customer),'cliente_cpf',p_cpf,'itens',(select jsonb_agg(jsonb_build_object('nome',produto_nome,'cor',cor,'tamanho',tamanho,'quantidade',quantidade,'preco_unitario',preco_unitario) order by produto_nome) from venda_itens where venda_id=sale),'trocas_total',credit,'valor_recebido',cash,'troco',greatest(coalesce(cash,0)-due,0)));
end $$;
grant execute on function public.finalizar_venda_completa(uuid,text,text,text,text,text,numeric,text,date,text) to authenticated;

create or replace function public.fechar_caixa_z(p_pdv_codigo text,p_chapa text,p_pin text) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare store uuid:=current_store_id(); terminal uuid; sup record; start_at timestamptz; end_at timestamptz:=now(); report jsonb; closeid uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into sup from operadores where loja_id=store and chapa=p_chapa and ativo and cargo in('gerente','supervisor') and pin_hash=crypt(p_pin,pin_hash); if not found then raise exception 'Autorização de gerente/supervisor inválida'; end if;
 select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo and ativo; if terminal is null then raise exception 'PDV inválido'; end if;
 select coalesce(max(periodo_fim),date_trunc('day',now())) into start_at from fechamentos_z where pdv_id=terminal;
 select jsonb_build_object('pdv',p_pdv_codigo,'periodo_inicio',start_at,'periodo_fim',end_at,
  'total_vendas',coalesce(sum(v.total) filter(where v.status='concluida'),0),'total_trocas',coalesce(sum(v.trocas_total) filter(where v.status='concluida'),0),'estornos',coalesce(sum(v.total) filter(where v.status='estornada'),0),
  'por_pagamento',coalesce((select jsonb_object_agg(forma_pagamento,valor) from (select forma_pagamento,sum(total) valor from vendas where pdv_id=terminal and status='concluida' and created_at>start_at and created_at<=end_at group by forma_pagamento) x),'{}'::jsonb),
  'por_operador',coalesce((select jsonb_agg(jsonb_build_object('chapa',chapa_snapshot,'operador',o.nome,'total',valor,'vendas',qtd,'celular',celular,'caixa',balcao)) from (select operador_id,chapa_snapshot,sum(total) valor,count(*) qtd,count(*) filter(where origem='celular') celular,count(*) filter(where origem='caixa') balcao from vendas where pdv_id=terminal and created_at>start_at and created_at<=end_at group by operador_id,chapa_snapshot) a join operadores o on o.id=a.operador_id),'[]'::jsonb),
  'pos',coalesce((select jsonb_agg(jsonb_build_object('marca',marca,'nsu',nsu,'data',data_transacao,'valor',valor)) from venda_pagamentos_pos p join vendas v on v.id=p.venda_id where v.pdv_id=terminal and v.created_at>start_at and v.created_at<=end_at),'[]'::jsonb),
  'trocas',coalesce((select jsonb_agg(jsonb_build_object('nota',t.numero_nota_fiscal,'valor',t.valor_credito,'quantidade',t.quantidade)) from trocas t join vendas v on v.id=t.venda_id where v.pdv_id=terminal and v.created_at>start_at and v.created_at<=end_at),'[]'::jsonb),
  'fundo_troco',coalesce((select sum(valor) from caixa_movimentos where pdv_id=terminal and tipo='fundo_troco' and created_at>start_at and created_at<=end_at),0),
  'sangrias',coalesce((select sum(valor) from caixa_movimentos where pdv_id=terminal and tipo='sangria' and created_at>start_at and created_at<=end_at),0)) into report
 from vendas v where v.pdv_id=terminal and v.created_at>start_at and v.created_at<=end_at;
 insert into fechamentos_z(loja_id,pdv_id,operador_id,periodo_inicio,periodo_fim,relatorio,fundo_troco,sangrias) values(store,terminal,sup.id,start_at,end_at,report,coalesce((report->>'fundo_troco')::numeric,0),coalesce((report->>'sangrias')::numeric,0)) returning id into closeid;
 update caixas_abertos set fechado_em=end_at,fechamento_id=closeid where pdv_id=terminal and fechado_em is null;
 return jsonb_build_object('id',closeid,'relatorio',report);
end $$;
grant execute on function public.fechar_caixa_z(text,text,text) to authenticated;

create or replace function public.auditoria_vendas(p_pdv_codigo text,p_chapa text,p_periodo text,p_mes date default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare store uuid:=current_store_id(); terminal uuid; desde timestamptz; ate timestamptz:=now(); rows jsonb; begin
 select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo; if terminal is null then raise exception 'PDV não encontrado'; end if;
 if p_periodo='hoje' then desde:=date_trunc('day',now()); elsif p_periodo='mes' then desde:=date_trunc('month',now()); elsif p_periodo='mes_passado' and p_mes is not null then desde:=date_trunc('month',p_mes); ate:=date_trunc('month',p_mes)+interval '1 month'; else raise exception 'Período inválido'; end if;
 select jsonb_build_object('total',coalesce(sum(total) filter(where status='concluida'),0),'quantidade',count(*),'vendas',coalesce(jsonb_agg(jsonb_build_object('id',id,'status',status,'created_at',created_at,'total',total,'forma_pagamento',forma_pagamento,'origem',origem,'trocas_total',trocas_total,'itens',(select jsonb_agg(jsonb_build_object('produto',produto_nome,'cor',cor,'tamanho',tamanho,'quantidade',quantidade,'subtotal',subtotal) order by produto_nome) from venda_itens i where i.venda_id=v.id),'pos',(select jsonb_agg(jsonb_build_object('marca',marca,'data',data_transacao,'nsu',nsu,'valor',valor)) from venda_pagamentos_pos p where p.venda_id=v.id),'trocas',(select jsonb_agg(jsonb_build_object('nota',numero_nota_fiscal,'valor',valor_credito,'quantidade',quantidade)) from trocas t where t.venda_id=v.id)) order by created_at desc),'[]'::jsonb)) into rows from vendas v where v.loja_id=store and v.pdv_id=terminal and v.chapa_snapshot=p_chapa and v.created_at>=desde and v.created_at<ate;
 return rows;
end $$;
grant execute on function public.auditoria_vendas(text,text,text,date) to authenticated;

create or replace function public.abrir_caixa(p_pdv_codigo text,p_chapa text,p_pin text,p_fundo numeric) returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare store uuid:=current_store_id(); terminal uuid; boss uuid; drawer uuid; begin
 if auth.uid() is null or p_fundo<0 then raise exception 'Fundo inválido'; end if;
 select id into boss from operadores where loja_id=store and chapa=p_chapa and ativo and cargo in('gerente','supervisor') and pin_hash=crypt(p_pin,pin_hash); if boss is null then raise exception 'Autorização de supervisor inválida'; end if;
 select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo and ativo; if terminal is null then raise exception 'PDV inválido'; end if;
 insert into caixas_abertos(loja_id,pdv_id,aberto_por,fundo_troco) values(store,terminal,boss,p_fundo) returning id into drawer;
 if p_fundo>0 then insert into caixa_movimentos(loja_id,pdv_id,caixa_id,operador_id,tipo,valor,motivo) values(store,terminal,drawer,boss,'fundo_troco',p_fundo,'Abertura de caixa'); end if; return drawer;
end $$;
grant execute on function public.abrir_caixa(text,text,text,numeric) to authenticated;

create or replace function public.registrar_sangria(p_pdv_codigo text,p_valor numeric,p_motivo text) returns uuid language plpgsql security definer set search_path=public as $$
declare store uuid:=current_store_id(); terminal uuid; drawer uuid; movement uuid; begin
 if auth.uid() is null or p_valor<=0 then raise exception 'Valor de sangria inválido'; end if;
 select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo and ativo; select id into drawer from caixas_abertos where pdv_id=terminal and fechado_em is null for update;
 if drawer is null then raise exception 'Caixa não está aberto'; end if;
 insert into caixa_movimentos(loja_id,pdv_id,caixa_id,operador_id,tipo,valor,motivo) values(store,terminal,drawer,current_operator_id(),'sangria',p_valor,coalesce(p_motivo,'')) returning id into movement; return movement;
end $$;
grant execute on function public.registrar_sangria(text,numeric,text) to authenticated;

create or replace function public.cancelar_item_carrinho(p_carrinho_id uuid,p_item_id uuid,p_chapa text,p_pin text) returns void language plpgsql security definer set search_path=public,extensions as $$
declare c carrinhos_ativos; boss uuid; begin
 select * into c from carrinhos_ativos where id=p_carrinho_id and loja_id=current_store_id() and status='aberto' for update; if not found then raise exception 'Carrinho indisponível'; end if;
 select id into boss from operadores where loja_id=c.loja_id and chapa=p_chapa and cargo in('gerente','supervisor') and ativo and pin_hash=crypt(p_pin,pin_hash); if boss is null then raise exception 'Autorização inválida'; end if;
 if not exists(select 1 from carrinho_itens where id=p_item_id and carrinho_id=c.id) then raise exception 'Item não encontrado'; end if;
 insert into auditoria_cancelamentos(loja_id,carrinho_id,item_id,operador_id,autorizado_por,tipo) values(c.loja_id,c.id,p_item_id,current_operator_id(),boss,'item'); delete from carrinho_itens where id=p_item_id and carrinho_id=c.id;
end $$;
grant execute on function public.cancelar_item_carrinho(uuid,uuid,text,text) to authenticated;

create or replace function public.estornar_venda(p_venda_id uuid,p_chapa text,p_pin text) returns void language plpgsql security definer set search_path=public,extensions as $$
declare s vendas; boss uuid; begin
 select * into s from vendas where id=p_venda_id and loja_id=current_store_id() for update; if not found then raise exception 'Venda não encontrada'; end if;
 select id into boss from operadores where loja_id=s.loja_id and chapa=p_chapa and cargo in('gerente','supervisor') and ativo and pin_hash=crypt(p_pin,pin_hash); if boss is null then raise exception 'Autorização inválida'; end if;
 if s.status='estornada' then raise exception 'Venda já estornada'; end if;
 update produto_variacoes v set estoque=v.estoque+i.quantidade from venda_itens i where i.venda_id=s.id and i.variacao_id=v.id;
 insert into auditoria_cancelamentos(loja_id,venda_id,operador_id,autorizado_por,tipo) values(s.loja_id,s.id,current_operator_id(),boss,'venda'); update vendas set status='estornada' where id=s.id;
end $$;
grant execute on function public.estornar_venda(uuid,text,text) to authenticated;
