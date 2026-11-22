-- Aplicar depois de schema.sql e schema-v2.sql.
revoke execute on function public.login_operador(text,text) from public,anon,authenticated;
revoke execute on function public.finalizar_venda(uuid,text,text,text,text) from public,anon,authenticated;
revoke select on table public.operadores from anon,authenticated;
grant select(id,loja_id,chapa,cargo,nome,ativo) on public.operadores to authenticated;
alter table public.operadores drop constraint if exists operadores_cargo_check;
alter table public.operadores add constraint operadores_cargo_check check(cargo in('assistente','lider','supervisor','gerente'));
alter table public.carrinhos_ativos add column if not exists desconto_total numeric(12,2) not null default 0 check(desconto_total>=0);
alter table public.vendas add column if not exists desconto_total numeric(12,2) not null default 0 check(desconto_total>=0);
create table public.logs_autorizacao_lideranca(id uuid primary key default gen_random_uuid(),loja_id uuid not null references public.lojas(id),pdv_id uuid references public.pdvs(id),operador_id uuid not null references public.operadores(id),chapa_autorizador text not null,autorizado_por uuid not null references public.operadores(id),acao text not null check(acao in('cancelamento_item','estorno_venda','desconto_manual','abertura_caixa','sangria','fechamento_z')),motivo text not null,valor numeric(12,2),carrinho_id uuid references public.carrinhos_ativos(id),venda_id uuid references public.vendas(id),created_at timestamptz not null default now());
create index logs_lideranca_store_date_idx on public.logs_autorizacao_lideranca(loja_id,created_at desc);
alter table public.logs_autorizacao_lideranca enable row level security;
create policy logs_lideranca_read on public.logs_autorizacao_lideranca for select to authenticated using(loja_id=current_store_id());

-- Privada para as RPCs SECURITY DEFINER; não conceder execução direta aos clientes.
create or replace function public.autorizar_lideranca(p_chapa text,p_pin text) returns uuid language plpgsql security definer set search_path=public,extensions as $$ declare result uuid; begin
 if auth.uid() is null or p_pin !~ '^\d{6}$' then raise exception 'Autorização inválida'; end if;
 select id into result from operadores where loja_id=current_store_id() and chapa=p_chapa and ativo and cargo in('lider','supervisor','gerente') and pin_hash=crypt(p_pin,pin_hash);
 if result is null then raise exception 'Chapa ou senha de liderança inválida'; end if; return result;
end $$;
revoke all on function public.autorizar_lideranca(text,text) from public,anon,authenticated;

create or replace function public.aplicar_desconto_carrinho(p_carrinho_id uuid,p_tipo text,p_valor numeric,p_chapa text,p_pin text,p_motivo text) returns numeric language plpgsql security definer set search_path=public as $$
declare c carrinhos_ativos; boss uuid; subtotal numeric; discount numeric; terminal uuid;
begin
 select * into c from carrinhos_ativos where id=p_carrinho_id and loja_id=current_store_id() and status='aberto' for update; if not found then raise exception 'Carrinho indisponível'; end if;
 boss:=autorizar_lideranca(p_chapa,p_pin); if coalesce(trim(p_motivo),'')='' then raise exception 'Motivo obrigatório'; end if;
 select coalesce(sum(i.quantidade*v.preco),0) into subtotal from carrinho_itens i join produto_variacoes v on v.id=i.variacao_id where i.carrinho_id=c.id;
 if p_tipo='percentual' then if p_valor<=0 or p_valor>100 then raise exception 'Percentual deve ser entre 0 e 100'; end if; discount:=round(subtotal*p_valor/100,2);
 elsif p_tipo='valor' then if p_valor<=0 or p_valor>subtotal then raise exception 'Desconto em valor inválido'; end if; discount:=p_valor; else raise exception 'Tipo de desconto inválido'; end if;
 update carrinhos_ativos set desconto_total=discount,updated_at=now() where id=c.id;
 select pdv_id into terminal from carrinhos_ativos where id=c.id;
 insert into logs_autorizacao_lideranca(loja_id,pdv_id,operador_id,chapa_autorizador,autorizado_por,acao,motivo,valor,carrinho_id) values(c.loja_id,terminal,current_operator_id(),p_chapa,boss,'desconto_manual',p_motivo,discount,c.id);
 return discount;
end $$;
grant execute on function public.aplicar_desconto_carrinho(uuid,text,numeric,text,text,text) to authenticated;
revoke execute on function public.aplicar_desconto_carrinho(uuid,text,numeric,text,text,text) from public,anon;

create or replace function public.abrir_caixa(p_pdv_codigo text,p_chapa text,p_pin text,p_fundo numeric,p_motivo text) returns uuid language plpgsql security definer set search_path=public as $$
declare store uuid:=current_store_id(); terminal uuid; boss uuid; drawer uuid;
begin
 if auth.uid() is null or p_fundo<0 or coalesce(trim(p_motivo),'')='' then raise exception 'Fundo e motivo inválidos'; end if;
 boss:=autorizar_lideranca(p_chapa,p_pin); select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo and ativo; if terminal is null then raise exception 'PDV inválido'; end if;
 insert into caixas_abertos(loja_id,pdv_id,aberto_por,fundo_troco) values(store,terminal,boss,p_fundo) returning id into drawer;
 if p_fundo>0 then insert into caixa_movimentos(loja_id,pdv_id,caixa_id,operador_id,tipo,valor,motivo) values(store,terminal,drawer,boss,'fundo_troco',p_fundo,'Abertura de caixa'); end if;
 insert into logs_autorizacao_lideranca(loja_id,pdv_id,operador_id,chapa_autorizador,autorizado_por,acao,motivo,valor) values(store,terminal,current_operator_id(),p_chapa,boss,'abertura_caixa',p_motivo,p_fundo); return drawer;
end $$;
grant execute on function public.abrir_caixa(text,text,text,numeric,text) to authenticated;
revoke execute on function public.abrir_caixa(text,text,text,numeric,text) from public,anon;
revoke execute on function public.abrir_caixa(text,text,text,numeric) from public,anon,authenticated;

create or replace function public.registrar_sangria(p_pdv_codigo text,p_valor numeric,p_motivo text,p_chapa text,p_pin text) returns uuid language plpgsql security definer set search_path=public as $$
declare store uuid:=current_store_id(); terminal uuid; drawer uuid; movement uuid; boss uuid; begin
 if auth.uid() is null or p_valor<=0 or coalesce(trim(p_motivo),'')='' then raise exception 'Valor/motivo de sangria inválido'; end if;
 boss:=autorizar_lideranca(p_chapa,p_pin); select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo and ativo; select id into drawer from caixas_abertos where pdv_id=terminal and fechado_em is null for update;
 if drawer is null then raise exception 'Caixa não está aberto'; end if;
 insert into caixa_movimentos(loja_id,pdv_id,caixa_id,operador_id,tipo,valor,motivo) values(store,terminal,drawer,current_operator_id(),'sangria',p_valor,p_motivo) returning id into movement;
 insert into logs_autorizacao_lideranca(loja_id,pdv_id,operador_id,chapa_autorizador,autorizado_por,acao,motivo,valor) values(store,terminal,current_operator_id(),p_chapa,boss,'sangria',p_motivo,p_valor); return movement;
end $$;
grant execute on function public.registrar_sangria(text,numeric,text,text,text) to authenticated;
revoke execute on function public.registrar_sangria(text,numeric,text,text,text) from public,anon;
revoke execute on function public.registrar_sangria(text,numeric,text) from public,anon,authenticated;

create or replace function public.cancelar_item_carrinho(p_carrinho_id uuid,p_item_id uuid,p_chapa text,p_pin text,p_motivo text) returns void language plpgsql security definer set search_path=public as $$
declare c carrinhos_ativos; boss uuid; terminal uuid; begin
 select * into c from carrinhos_ativos where id=p_carrinho_id and loja_id=current_store_id() and status='aberto' for update; if not found then raise exception 'Carrinho indisponível'; end if;
 if coalesce(trim(p_motivo),'')='' then raise exception 'Motivo obrigatório'; end if; boss:=autorizar_lideranca(p_chapa,p_pin); if not exists(select 1 from carrinho_itens where id=p_item_id and carrinho_id=c.id) then raise exception 'Item não encontrado'; end if;
 insert into auditoria_cancelamentos(loja_id,carrinho_id,item_id,operador_id,autorizado_por,tipo) values(c.loja_id,c.id,p_item_id,current_operator_id(),boss,'item');
 select pdv_id into terminal from carrinhos_ativos where id=c.id;
 insert into logs_autorizacao_lideranca(loja_id,pdv_id,operador_id,chapa_autorizador,autorizado_por,acao,motivo,carrinho_id) values(c.loja_id,terminal,current_operator_id(),p_chapa,boss,'cancelamento_item',p_motivo,c.id);
 delete from carrinho_itens where id=p_item_id and carrinho_id=c.id;
end $$;
grant execute on function public.cancelar_item_carrinho(uuid,uuid,text,text,text) to authenticated;
revoke execute on function public.cancelar_item_carrinho(uuid,uuid,text,text,text) from public,anon;
revoke execute on function public.cancelar_item_carrinho(uuid,uuid,text,text) from public,anon,authenticated;

create or replace function public.estornar_venda(p_venda_id uuid,p_chapa text,p_pin text,p_motivo text) returns void language plpgsql security definer set search_path=public as $$
declare s vendas; boss uuid; begin
 select * into s from vendas where id=p_venda_id and loja_id=current_store_id() for update; if not found then raise exception 'Venda não encontrada'; end if;
 if coalesce(trim(p_motivo),'')='' then raise exception 'Motivo obrigatório'; end if; boss:=autorizar_lideranca(p_chapa,p_pin); if s.status='estornada' then raise exception 'Venda já estornada'; end if;
 update produto_variacoes v set estoque=v.estoque+i.quantidade from venda_itens i where i.venda_id=s.id and i.variacao_id=v.id;
 insert into auditoria_cancelamentos(loja_id,venda_id,operador_id,autorizado_por,tipo) values(s.loja_id,s.id,current_operator_id(),boss,'venda');
 insert into logs_autorizacao_lideranca(loja_id,pdv_id,operador_id,chapa_autorizador,autorizado_por,acao,motivo,valor,venda_id) values(s.loja_id,s.pdv_id,current_operator_id(),p_chapa,boss,'estorno_venda',p_motivo,s.total,s.id);
 update vendas set status='estornada' where id=s.id;
end $$;
grant execute on function public.estornar_venda(uuid,text,text,text) to authenticated;
revoke execute on function public.estornar_venda(uuid,text,text,text) from public,anon;
revoke execute on function public.estornar_venda(uuid,text,text) from public,anon,authenticated;

-- RPC privada para incluir o resumo das autorizações no relatório Z e registrar quem encerrou o movimento.
create or replace function public.fechar_caixa_z(p_pdv_codigo text,p_chapa text,p_pin text,p_motivo text) returns jsonb language plpgsql security definer set search_path=public as $$
declare boss uuid; terminal uuid; store uuid:=current_store_id(); closeid uuid; start_at timestamptz; end_at timestamptz:=now(); report jsonb;
begin
 if coalesce(trim(p_motivo),'')='' then raise exception 'Motivo obrigatório'; end if; boss:=autorizar_lideranca(p_chapa,p_pin);
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
 insert into logs_autorizacao_lideranca(loja_id,pdv_id,operador_id,chapa_autorizador,autorizado_por,acao,motivo,created_at) values(store,terminal,current_operator_id(),p_chapa,boss,'fechamento_z',p_motivo,end_at);
 report:=report||jsonb_build_object('autorizacoes',coalesce((select jsonb_agg(jsonb_build_object('acao',acao,'chapa',chapa_autorizador,'motivo',motivo,'valor',valor,'horario',created_at) order by created_at) from logs_autorizacao_lideranca where pdv_id=terminal and created_at>start_at and created_at<=end_at),'[]'::jsonb));
 insert into fechamentos_z(loja_id,pdv_id,operador_id,periodo_inicio,periodo_fim,relatorio,fundo_troco,sangrias) values(store,terminal,boss,start_at,end_at,report,coalesce((report->>'fundo_troco')::numeric,0),coalesce((report->>'sangrias')::numeric,0)) returning id into closeid;
 update caixas_abertos set fechado_em=end_at,fechamento_id=closeid where pdv_id=terminal and fechado_em is null;
 return jsonb_build_object('id',closeid,'relatorio',report);
end $$;
grant execute on function public.fechar_caixa_z(text,text,text,text) to authenticated;
revoke execute on function public.fechar_caixa_z(text,text,text,text) from public,anon;
revoke execute on function public.fechar_caixa_z(text,text,text) from public,anon,authenticated;

create or replace function public.finalizar_venda_completa(p_carrinho_id uuid,p_pdv_codigo text,p_cpf text,p_nome text,p_email text,p_forma_pagamento text,p_valor_recebido numeric default null,p_pos_marca text default null,p_pos_data date default null,p_pos_nsu text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c carrinhos_ativos; store uuid; terminal uuid; customer uuid; sale uuid; gross numeric(12,2); credit numeric(12,2); discount numeric(12,2); due numeric(12,2); cash numeric(12,2); item record;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; store:=current_store_id();
 select id into terminal from pdvs where loja_id=store and codigo=p_pdv_codigo and ativo; if terminal is null then raise exception 'PDV inválido'; end if;
 if not exists(select 1 from caixas_abertos where pdv_id=terminal and fechado_em is null) then raise exception 'Abra o caixa com fundo de troco antes de vender'; end if;
 select * into c from carrinhos_ativos where id=p_carrinho_id and status='aberto' and loja_id=store for update; if not found then raise exception 'Carrinho indisponível'; end if;
 if not exists(select 1 from carrinho_itens where carrinho_id=c.id) then raise exception 'Carrinho vazio'; end if;
 if p_cpf is not null then if p_cpf !~ '^\d{11}$' or coalesce(trim(p_nome),'')='' then raise exception 'Dados do cliente inválidos'; end if; insert into clientes(loja_id,cpf,nome,email) values(store,p_cpf,p_nome,nullif(p_email,'')) on conflict(loja_id,cpf) do update set nome=excluded.nome,email=excluded.email,updated_at=now() returning id into customer; end if;
 for item in select v.id,v.estoque,i.quantidade from produto_variacoes v join carrinho_itens i on i.variacao_id=v.id where i.carrinho_id=c.id order by v.id for update of v loop if item.estoque<item.quantidade then raise exception 'Estoque insuficiente'; end if; end loop;
 select coalesce(sum(i.quantidade*v.preco),0) into gross from carrinho_itens i join produto_variacoes v on v.id=i.variacao_id where i.carrinho_id=c.id;
 select coalesce(sum(valor_credito),0) into credit from trocas where carrinho_id=c.id and status='pendente'; discount:=c.desconto_total;
 if discount>gross or credit>gross-discount then raise exception 'Desconto e crédito de troca excedem o valor dos itens'; end if; due:=gross-discount-credit;
 if p_forma_pagamento not in('debito','credito','dinheiro','pos','pix') then raise exception 'Forma de pagamento inválida'; end if;
 if p_forma_pagamento='dinheiro' and (p_valor_recebido is null or p_valor_recebido<due) then raise exception 'Valor recebido insuficiente'; end if;
 if p_forma_pagamento='pos' and due>0 and (p_pos_marca not in('visa','mastercard','elo','amex','hipercard','pix') or p_pos_data is null or coalesce(trim(p_pos_nsu),'')='') then raise exception 'Marca, data e NSU da POS são obrigatórios'; end if;
 insert into vendas(loja_id,operador_id,cliente_id,total,forma_pagamento,origem_carrinho_id,pdv_id,chapa_snapshot,origem,trocas_total,desconto_total) values(store,c.operador_id,customer,due,p_forma_pagamento,c.id,terminal,(select chapa from operadores where id=c.operador_id),c.origem,credit,discount) returning id into sale;
 insert into venda_itens(venda_id,variacao_id,produto_nome,cor,tamanho,quantidade,preco_unitario,subtotal,codigo_sku,codigo_barras,produto_id) select sale,v.id,p.nome,v.cor,v.tamanho,i.quantidade,v.preco,i.quantidade*v.preco,v.sku,v.codigo_barras,p.id from carrinho_itens i join produto_variacoes v on v.id=i.variacao_id join produtos p on p.id=v.produto_id where i.carrinho_id=c.id;
 update produto_variacoes v set estoque=v.estoque-i.quantidade from carrinho_itens i where i.carrinho_id=c.id and i.variacao_id=v.id;
 update produto_variacoes v set estoque=v.estoque+t.quantidade from trocas t where t.carrinho_id=c.id and t.status='pendente' and t.variacao_id=v.id;
 update trocas set status='concluida',venda_id=sale where carrinho_id=c.id and status='pendente';
 if p_forma_pagamento='pos' and due>0 then insert into venda_pagamentos_pos(loja_id,venda_id,marca,data_transacao,nsu,valor) values(store,sale,p_pos_marca,p_pos_data,p_pos_nsu,due); end if;
 update carrinhos_ativos set status='finalizado',pdv_id=terminal,updated_at=now() where id=c.id;
 return jsonb_build_object('loja',(select jsonb_build_object('nome_fantasia',nome_fantasia,'cnpj',cnpj,'endereco',endereco,'telefone',telefone) from lojas where id=store),'venda',jsonb_build_object('id',sale,'created_at',now(),'total',due,'forma_pagamento',p_forma_pagamento,'operador',(select nome from operadores where id=c.operador_id),'cliente_nome',(select nome from clientes where id=customer),'cliente_cpf',p_cpf,'pdv_codigo',p_pdv_codigo,'desconto_total',discount,'trocas_total',credit,'valor_recebido',p_valor_recebido,'troco',greatest(coalesce(p_valor_recebido,0)-due,0),'itens',(select jsonb_agg(jsonb_build_object('nome',produto_nome,'cor',cor,'tamanho',tamanho,'quantidade',quantidade,'preco_unitario',preco_unitario) order by produto_nome) from venda_itens where venda_id=sale)));
end $$;
grant execute on function public.finalizar_venda_completa(uuid,text,text,text,text,text,numeric,text,date,text) to authenticated;
revoke execute on function public.finalizar_venda_completa(uuid,text,text,text,text,text,numeric,text,date,text) from public,anon;
