# PDV SaaS — base funcional

## Estrutura

```text
src/
  app/                 rotas App Router, PWA e estilos globais
  components/           PDVWorkspace, CaixaDesktop, BobinaTermica, PortalAuditoria e EntradaEstoque
  lib/supabase.ts        cliente Supabase e tipos
supabase/schema.sql      tabelas, índices, RLS e RPCs
public/                  manifest e service worker
supabase/                schema inicial e migrações v2/v3/v4/v5/v6/v7
```

## Rodar localmente

1. Instale Node.js 20+ e dependências com `npm install`.
2. Copie `.env.example` para `.env.local` e informe URL e chave anon do Supabase.
3. Execute `supabase/schema.sql`, `supabase/schema-v2.sql`, `supabase/schema-v3.sql`, `supabase/schema-v4.sql`, `supabase/schema-v5.sql`, `supabase/schema-v6.sql` e `supabase/schema-v7.sql` nessa ordem no SQL Editor do projeto Supabase.
4. Inicie com `npm run dev`; abra `/caixa` para o caixa por chapa, `/portal-auditoria` para consultas e `/estoque/entrada` para entrada em lote. `/` mantém a tela de PDV mobile inicial.
5. Publique em HTTPS para permitir acesso à câmera e instale como PWA pelo navegador.

## Cadastrar uma loja cliente

1. No Supabase Auth, crie um usuário administrativo com e-mail e uma senha forte. Esse usuário não deve ser um operador de loja.
2. No ambiente da hospedagem (ou no `.env.local` somente para desenvolvimento), configure `SUPABASE_SECRET_KEY` com a chave secreta do servidor e `PLATFORM_ADMIN_EMAILS` com o e-mail administrativo autorizado. A chave secreta não pode ter prefixo `NEXT_PUBLIC_` e nunca deve ser commitada.
3. Abra `/admin/lojas`, entre com a conta administrativa e cadastre os dados da loja, do primeiro PDV e do gerente.
4. Entregue ao gerente o código da loja, a chapa e o PIN inicial por um canal seguro. Ele acessa `/caixa` no computador da loja; a identidade visual pode ser ajustada em `/admin/identidade` após entrar.

A rota administrativa valida a sessão Supabase e uma lista de e-mails autorizados no servidor. A chave secreta fica somente na rota de servidor; a RPC `admin_provisionar_loja` só aceita chamadas com a função de banco `service_role` e cria loja, PDV e gerente em uma transação. A rota também cria o usuário Auth com confirmação administrativa e remove esse usuário se a criação dos registros falhar. Cada loja tem um código de acesso próprio, exigido junto da chapa e do PIN para impedir ambiguidade entre lojas.

## Provisionamento dos operadores

O login mantém a sessão por Supabase Auth. O fluxo administrativo cria uma senha Auth aleatória separada do PIN; o PIN fica em hash bcrypt em `operadores` e a senha Auth fica na tabela interna `operador_segredos`, sem leitura direta pelo cliente. A RPC `login_chapa` exige código da loja, chapa e PIN; somente após validar o PIN ela devolve a credencial Auth necessária ao login. Nunca exponha a chave secreta/service_role no browser.

PIN numérico de seis dígitos é um segredo de baixa entropia. A migração v7 adiciona bloqueio temporário por tentativas de login e validação de liderança, além de tokens de uso único com expiração para ações protegidas. Antes de produção, revise o rate limit/IP no ambiente publicado, monitore bloqueios e defina recuperação segura do PIN. Considere credencial mais forte para caixas compartilhados.

## Operação e limites desta base

- `finalizar_venda_completa` bloqueia carrinho e variações, confere estoque, registra venda/itens, cliente e troca, movimenta o estoque em uma transação PostgreSQL. Exige abertura de caixa para o PDV e registra dados da POS quando escolhida.
- `schema-v2.sql` adiciona chapa/cargo, PDVs, POS, trocas, abertura/fundo de caixa, sangrias, cancelamento/estorno, Relatório Z e portal de auditoria. `schema-v3.sql` amplia os cargos para `lider`, exige autorização e motivo em ações críticas, grava `logs_autorizacao_lideranca`, aplica desconto auditável e habilita cupom de troca sem preços (F10).
- `schema-v4.sql` revoga gravações diretas do navegador nas tabelas, restringe entrada de estoque à liderança com trilha de movimentação, limita auditoria a supervisor/gerente, controla o crédito da troca pelo preço devolvido e habilita Realtime para itens de carrinho.
- `schema-v5.sql` adiciona nome, URL de logotipo e cores por loja. O tema é carregado após a autenticação e atualizado via Realtime. Gerentes e supervisores podem configurar em `/admin/identidade`.
- `schema-v6.sql` adiciona o provisionamento restrito de novos clientes, gera um código de acesso por loja e exige esse código no login por chapa; `/admin/lojas` cadastra loja, primeiro PDV e gerente. O e-mail Auth do operador é sintético e o gerente entra com código da loja, chapa e PIN.
- `schema-v7.sql` limita tentativas de PIN, separa a senha aleatória do Supabase Auth do PIN do operador e exige token de uso único para cancelar, estornar, descontar, abrir/sangrar ou fechar o caixa.
- `CaixaDesktop` implementa N, Z, F2, T, D, Espaço, F3/F4/F6/F7/F8/F9/F10. O backup local do carrinho fica em `sessionStorage` durante sincronização; os dados persistentes seguem no Supabase.
- Crie operadores com cargo `assistente`, `lider`, `supervisor` ou `gerente`. Para a migração existente, preencha chapas únicas antes de exigir `chapa NOT NULL` na sua política operacional.
- As políticas RLS restringem os dados por loja derivada do usuário autenticado. Faça o provisionamento inicial de loja/produtos por backend administrativo, nunca pela chave anon sem política apropriada.
- O PWA instala e oferece fallback do shell; operações de venda exigem rede, pois Supabase Realtime e as RPCs são online. Os carrinhos ficam persistidos no servidor.
- A câmera usa `html5-qrcode`; o debounce é aplicado no callback para evitar a mesma etiqueta em sequência muito rápida. A permissão da câmera exige HTTPS. O beep tenta carregar `/beep.mp3`; caso não seja fornecido, vibração continua disponível.
- A impressão do novo caixa e do Relatório Z é exclusiva para bobina de 80 mm. Configure o driver da impressora com essa largura.
- Antes de produção: valide documentos fiscais e obrigações locais com contabilidade, políticas de retenção/consentimento, backup, observabilidade, gestão de usuários e regras de cancelamento/devolução. O recibo implementado é não fiscal.
- Pendências conhecidas: revisar rate limit e monitoramento no ambiente publicado; leitura de CPF/chapa restrita a RPCs; validar nota fiscal contra venda original; devolver crédito da troca em estorno e impedir autoautorização; proteger atalhos quando o foco sai do campo do código; configurar PDV por terminal sem valor padrão; gestão de planos e cobrança recorrente; pagamento misto; conferência de numerário no Z; integração NFC-e quando necessária.
