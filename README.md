# PDV SaaS — base funcional

## Estrutura

```text
src/
  app/                 rotas App Router, PWA e estilos globais
  components/           PDVWorkspace, CaixaDesktop, BobinaTermica, PortalAuditoria e EntradaEstoque
  lib/supabase.ts        cliente Supabase e tipos
supabase/schema.sql      tabelas, índices, RLS e RPCs
public/                  manifest e service worker
supabase/                schema inicial e migrações v2/v3
```

## Rodar localmente

1. Instale Node.js 20+ e dependências com `npm install`.
2. Copie `.env.example` para `.env.local` e informe URL e chave anon do Supabase.
3. Execute `supabase/schema.sql`, `supabase/schema-v2.sql` e `supabase/schema-v3.sql` nessa ordem no SQL Editor do projeto Supabase.
4. Inicie com `npm run dev`; abra `/caixa` para o caixa por chapa, `/portal-auditoria` para consultas e `/estoque/entrada` para entrada em lote. `/` mantém a tela de PDV mobile inicial.
5. Publique em HTTPS para permitir acesso à câmera e instale como PWA pelo navegador.

## Provisionamento dos operadores

O login mantém a sessão por Supabase Auth. Para cada operador, crie um usuário Auth por fluxo administrativo confiável, com e-mail sintético único e senha PIN, depois grave `auth_user_id`, `auth_email`, `cpf`, `chapa`, `cargo` e `pin_hash = crypt(PIN, gen_salt('bf'))` em `operadores`. Crie também o PDV com código único e configure esse código no terminal. Nunca exponha a chave `service_role` no browser. A RPC `login_chapa` confere a chapa e o hash antes de devolver o endereço Auth usado pelo cliente.

PIN numérico de seis dígitos é um segredo de baixa entropia. Em produção, coloque o login atrás de uma Edge Function com limitação por CPF/IP/dispositivo, atraso progressivo, trilha de auditoria, bloqueio temporário e monitoramento; configure expiração/recuperação segura de PIN. Não libere a RPC pública diretamente na internet sem esse controle. Considere credencial maior ou passkey para caixas compartilhados.

## Operação e limites desta base

- `finalizar_venda_completa` bloqueia carrinho e variações, confere estoque, registra venda/itens, cliente e troca, movimenta o estoque em uma transação PostgreSQL. Exige abertura de caixa para o PDV e registra dados da POS quando escolhida.
- `schema-v2.sql` adiciona chapa/cargo, PDVs, POS, trocas, abertura/fundo de caixa, sangrias, cancelamento/estorno, Relatório Z e portal de auditoria. `schema-v3.sql` amplia os cargos para `lider`, exige autorização e motivo em ações críticas, grava `logs_autorizacao_lideranca`, aplica desconto auditável e habilita cupom de troca sem preços (F10).
- `CaixaDesktop` implementa N, Z, F2, T, D, Espaço, F3/F4/F6/F7/F8/F9/F10. O backup local do carrinho fica em `sessionStorage` durante sincronização; os dados persistentes seguem no Supabase.
- Crie operadores com cargo `assistente`, `lider`, `supervisor` ou `gerente`. Para a migração existente, preencha chapas únicas antes de exigir `chapa NOT NULL` na sua política operacional.
- As políticas RLS restringem os dados por loja derivada do usuário autenticado. Faça o provisionamento inicial de loja/produtos por backend administrativo, nunca pela chave anon sem política apropriada.
- O PWA instala e oferece fallback do shell; operações de venda exigem rede, pois Supabase Realtime e as RPCs são online. Os carrinhos ficam persistidos no servidor.
- A câmera usa `html5-qrcode`; o debounce é aplicado no callback para evitar a mesma etiqueta em sequência muito rápida. A permissão da câmera exige HTTPS. O beep tenta carregar `/beep.mp3`; caso não seja fornecido, vibração continua disponível.
- A impressão do novo caixa e do Relatório Z é exclusiva para bobina de 80 mm. Configure o driver da impressora com essa largura.
- Antes de produção: valide documentos fiscais e obrigações locais com contabilidade, políticas de retenção/consentimento, backup, observabilidade, gestão de usuários e regras de cancelamento/devolução. O recibo implementado é não fiscal.
