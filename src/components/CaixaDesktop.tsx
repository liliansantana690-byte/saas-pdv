"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import BobinaTermica, { type ZReport } from "./BobinaTermica";
import type { Receipt } from "./ReciboTermico";
import { TenantBrandMark, useTenantBranding } from "./TenantBranding";

type Item={id:string;variacao_id:string;quantidade:number;variacao:{sku:string;codigo_barras:string|null;cor:string;tamanho:string;preco:number;produto:{nome:string}}};
type Operator={id:string;loja_id:string;nome:string;cargo:string;chapa:string};
const brl=(n:number)=>Number(n||0).toLocaleString("pt-BR",{style:"currency",currency:"BRL"});
const HELP_KEYS: [string,string,string?][] = [
 ["X","Mostrar esta lista"],
 ["F1","Calculadora"],
 ["F2","Abrir operador"],
 ["F3","Fechar operador"],
 ["F4","Débito"],
 ["F5","Crédito"],
 ["F6","Dinheiro"],
 ["F7","POS (maquininha): data, NSU e bandeira"],
 ["F8","PIX com QR Code da loja","em breve"],
 ["F9","Consultar preço"],
 ["R","Devolução","em breve"],
 ["T","Vale troca"],
 ["D","Cupom de desconto","em breve"],
 ["End","Desconto manual (matrícula da liderança)"],
 ["W","Recuperar pedido"],
 ["Z","Fechamento Z"],
 ["G","Sangria"],
 ["Insert","Vendedor","em breve"],
 ["Delete","Cancelar item"],
 ["PageDown","Alterar preço","em breve"],
 ["Espaço","Finalizar venda"],
 ["Esc","Fechar janela"],
];
// Cálculo sem eval: multiplicação e divisão primeiro, depois soma e subtração.
function calcEval(s:string):number|null{
 const t=s.replace(/\s+/g,"").replace(/,/g,".").match(/\d+(\.\d+)?|[+\-*/]/g); if(!t||t.length%2===0) return null;
 const parts:(number|string)[]=[]; let cur=Number(t[0]); if(Number.isNaN(cur)) return null;
 for(let i=1;i<t.length;i+=2){const op=t[i],n=Number(t[i+1]); if(Number.isNaN(n)) return null;
  if(op==="*") cur*=n; else if(op==="/"){ if(n===0) return null; cur/=n; } else { parts.push(cur,op); cur=n; } }
 parts.push(cur); let total=Number(parts[0]);
 for(let j=1;j<parts.length;j+=2){const op=parts[j] as string,n=Number(parts[j+1]); total= op==="+"?total+n:total-n;}
 return Math.round(total*100)/100;
}
const pinRegex=/^\d{6}$/;
export default function CaixaDesktop(){
 const { brand: tenantBrand } = useTenantBranding();
 const [op,setOp]=useState<Operator|null>(null),[pdv,setPdv]=useState("523"),[storeAccessCode,setStoreAccessCode]=useState(""),[cartId,setCartId]=useState<string|null>(null),[rows,setRows]=useState<Item[]>([]),[credit,setCredit]=useState(0),[discount,setDiscount]=useState(0),[code,setCode]=useState(""),[checkout,setCheckout]=useState(false),[modal,setModal]=useState(""),[error,setError]=useState(""),[cpf,setCpf]=useState(""),[client,setClient]=useState({nome:"",email:""}),[pay,setPay]=useState("debito"),[cash,setCash]=useState(""),[brand,setBrand]=useState("visa"),[posDate,setPosDate]=useState(""),[nsu,setNsu]=useState(""),[returnCode,setReturnCode]=useState(""),[returnNf,setReturnNf]=useState(""),[returnValue,setReturnValue]=useState(""),[receipt,setReceipt]=useState<Receipt|null>(null),[receiptMode,setReceiptMode]=useState<"venda"|"troca">("venda"),[zreport,setZreport]=useState<ZReport|null>(null),[managerChapa,setManagerChapa]=useState(""),[managerPin,setManagerPin]=useState(""),[reason,setReason]=useState(""),[fund,setFund]=useState(""),[withdraw,setWithdraw]=useState(""),[discountType,setDiscountType]=useState("valor"),[discountValue,setDiscountValue]=useState(""),[cancelType,setCancelType]=useState("item"),[cancelTarget,setCancelTarget]=useState("");
 const codeRef=useRef<HTMLInputElement>(null), total=rows.reduce((a,r)=>a+r.quantidade*Number(r.variacao.preco),0);
 const [catalog,setCatalog]=useState<any[]>([]),[filtro,setFiltro]=useState(""),[ultimaVenda,setUltimaVenda]=useState<Receipt|null>(null),[online,setOnline]=useState(true),[agora,setAgora]=useState(()=>new Date());
 useEffect(()=>{if(!op)return;void supabase.from("produto_variacoes").select("id,sku,codigo_barras,cor,tamanho,preco,estoque,produto:produtos(nome)").order("sku").then(({data})=>setCatalog(data||[]));},[op]);
 useEffect(()=>{const t=setInterval(()=>setAgora(new Date()),30000);const on=()=>setOnline(true),off=()=>setOnline(false);window.addEventListener("online",on);window.addEventListener("offline",off);setOnline(navigator.onLine);return()=>{clearInterval(t);window.removeEventListener("online",on);window.removeEventListener("offline",off);};},[]);
 const [helpOpen,setHelpOpen]=useState(false),[calcExpr,setCalcExpr]=useState(""),[priceQuery,setPriceQuery]=useState(""),[priceResult,setPriceResult]=useState<any>(null);
 async function consultPrice(){const v=priceQuery.trim();if(!v)return;setPriceResult(null);const cols="sku,cor,tamanho,preco,estoque,produto:produtos(nome)";let {data}=await supabase.from("produto_variacoes").select(cols).eq("codigo_barras",v).maybeSingle();if(!data)({data}=await supabase.from("produto_variacoes").select(cols).eq("sku",v).maybeSingle());setPriceResult(data||"nao");}
 function payWith(p:string){if(!rows.length)return;setPay(p);if(p==="pos")setModal("pos");setCheckout(true);}
 useEffect(()=>{setPdv(localStorage.getItem("pdv-code")||"523");setStoreAccessCode(localStorage.getItem("store-access-code")||""); const {data}=supabase.auth.onAuthStateChange(async(_e,s)=>{if(!s){setOp(null);return;} const {data:o}=await supabase.from("operadores").select("id,loja_id,nome,cargo,chapa").eq("auth_user_id",s.user.id).maybeSingle(); if(o){setOp(o);}}); void supabase.auth.getSession().then(async({data})=>{if(data.session){const {data:o}=await supabase.from("operadores").select("id,loja_id,nome,cargo,chapa").eq("auth_user_id",data.session.user.id).maybeSingle();if(o)setOp(o);}});return()=>data.subscription.unsubscribe();},[]);
 useEffect(()=>{localStorage.setItem("pdv-code",pdv);},[pdv]);
 const refresh=useCallback(async(id=cartId)=>{if(!id)return;const [{data,error:e},{data:trades},{data:cart}]=await Promise.all([supabase.from("carrinho_itens").select("id,variacao_id,quantidade,variacao:produto_variacoes(sku,codigo_barras,cor,tamanho,preco,produto:produtos(nome))").eq("carrinho_id",id),supabase.from("trocas").select("valor_credito").eq("carrinho_id",id).eq("status","pendente"),supabase.from("carrinhos_ativos").select("desconto_total").eq("id",id).single()]);if(e){setError(e.message);const backup=sessionStorage.getItem(`cart:${id}`);if(backup)setRows(JSON.parse(backup));}else{const list=(data||[]) as unknown as Item[];setRows(list);sessionStorage.setItem(`cart:${id}`,JSON.stringify(list));}setCredit((trades||[]).reduce((a,t)=>a+Number(t.valor_credito),0));setDiscount(Number(cart?.desconto_total||0));},[cartId]);
 useEffect(()=>{if(!cartId)return;void refresh();const ch=supabase.channel(`checkout-cart-${cartId}`).on("postgres_changes",{event:"*",schema:"public",table:"carrinho_itens",filter:`carrinho_id=eq.${cartId}`},()=>void refresh()).subscribe();return()=>{void supabase.removeChannel(ch);};},[cartId,refresh]);
 async function login(fd:FormData){const chapa=String(fd.get("chapa")||"").trim(),pin=String(fd.get("pin")||""),storeCode=String(fd.get("storeCode")||"").trim().toUpperCase();if(!/^[A-F0-9]{12}$/.test(storeCode)){setError("Informe o código da loja recebido do administrador.");return;}if(!pinRegex.test(pin)){setError("Senha deve ter 6 dígitos.");return;}const {data,error:e}=await supabase.rpc("login_chapa",{p_codigo_acesso:storeCode,p_chapa:chapa,p_pin:pin});const user=data?.[0];if(e||!user){setError("Código da loja, chapa ou senha inválidos.");return;}const {error:ae}=await supabase.auth.signInWithPassword({email:user.auth_email,password:user.auth_senha});if(ae){setError("Usuário Supabase não provisionado para esta chapa.");return;}localStorage.setItem("store-access-code",storeCode);setStoreAccessCode(storeCode);const {data:o}=await supabase.from("operadores").select("id,loja_id,nome,cargo,chapa").eq("id",user.id).single();setOp(o);const {data:c,error:ce}=await supabase.from("carrinhos_ativos").insert({loja_id:user.loja_id,operador_id:user.id,pdv_id:null,origem:"caixa"}).select("id").single();if(ce)setError(ce.message);else setCartId(c.id);}
 async function scan(value=code){if(!cartId||!value.trim())return;const v=value.trim();setCode("");let {data,error:e}=await supabase.from("produto_variacoes").select("id").eq("codigo_barras",v).maybeSingle();if(!data&&!e)({data,error:e}=await supabase.from("produto_variacoes").select("id").eq("sku",v).maybeSingle());if(e||!data){setError(e?.message||`Código/SKU não encontrado: ${v}`);return;}const {error:ae}=await supabase.rpc("adicionar_item_carrinho",{p_carrinho_id:cartId,p_variacao_id:data.id,p_quantidade:1});if(ae)setError(ae.message);else{setError("");try{navigator.vibrate?.(45);new Audio("/beep.mp3").play().catch(()=>{});}catch{}await refresh();}}
 async function start(){if(!op)return;const {data,error:e}=await supabase.from("carrinhos_ativos").insert({loja_id:op.loja_id,operador_id:op.id,origem:"caixa"}).select("id").single();if(e)setError(e.message);else setCartId(data.id);}
async function findClient(v:string){const digits=v.replace(/\D/g,"").slice(0,11);setCpf(digits);if(digits.length===11){const {data}=await supabase.rpc("buscar_cliente",{p_cpf:digits});setClient(data||{nome:"",email:""});}else setClient({nome:"",email:""});}
function erro(err:unknown){return err instanceof Error?err.message:((err as {message?:string})?.message||"Falha na operação.");}
// Pede o token de liderança. O PIN é conferido no servidor, com bloqueio, e o token vale só para esta ação, por 90 s.
async function autorizar(acao:string){const {data,error:e}=await supabase.rpc("validar_lideranca",{p_chapa:managerChapa,p_pin:managerPin,p_acao:acao});if(e)throw e;if(!data?.ok)throw new Error(data?.erro||"Autorização negada.");return String(data.token);}
 async function addReturn(){if(!cartId)return;const {error:e}=await supabase.rpc("adicionar_troca_carrinho",{p_carrinho_id:cartId,p_codigo:returnCode,p_nota_fiscal:returnNf,p_valor:Number(returnValue),p_quantidade:1});if(e)setError(e.message);else{setError("");setModal("");setReturnCode("");setReturnNf("");setReturnValue("");await refresh();}}
 async function complete(){if(!cartId)return;const {data,error:e}=await supabase.rpc("finalizar_venda_completa",{p_carrinho_id:cartId,p_pdv_codigo:pdv,p_cpf:cpf||null,p_nome:client.nome||null,p_email:client.email||null,p_forma_pagamento:pay,p_valor_recebido:pay==="dinheiro"?Number(cash):null,p_pos_marca:pay==="pos"?brand:null,p_pos_data:pay==="pos"?posDate:null,p_pos_nsu:pay==="pos"?nsu:null});if(e){setError(e.message);return;}sessionStorage.removeItem(`cart:${cartId}`);const completed=data as Receipt;completed.loja.logo_url=tenantBrand.logo_url;setReceipt(completed);setUltimaVenda(completed);setReceiptMode("venda");setCartId(null);setRows([]);setCredit(0);setDiscount(0);setCheckout(false);setError("");}
 async function lockOperator(){await supabase.auth.signOut();setOp(null);setCartId(null);setRows([]);setCheckout(false);}
async function closeZ(){try{const token=await autorizar("fechamento_z");const {data,error:e}=await supabase.rpc("fechar_caixa_z",{p_pdv_codigo:pdv,p_motivo:reason,p_token:token});if(e)throw e;setZreport(data.relatorio as ZReport);setModal("");setManagerPin("");setReason("");}catch(err){setError(erro(err));}}
async function openTill(){try{const token=await autorizar("abertura_caixa");const {error:e}=await supabase.rpc("abrir_caixa",{p_pdv_codigo:pdv,p_token:token,p_fundo:Number(fund),p_motivo:reason});if(e)throw e;setModal("");setError("");setManagerPin("");setReason("");}catch(err){setError(erro(err));}}
async function sangria(){try{const token=await autorizar("sangria");const {error:e}=await supabase.rpc("registrar_sangria",{p_pdv_codigo:pdv,p_valor:Number(withdraw),p_motivo:reason,p_token:token});if(e)throw e;setModal("");setWithdraw("");setManagerPin("");setReason("");}catch(err){setError(erro(err));}}
async function cancel(){try{const token=await autorizar(cancelType==="item"?"cancelamento_item":"estorno_venda");const {error:e}=cancelType==="item"?await supabase.rpc("cancelar_item_carrinho",{p_carrinho_id:cartId,p_item_id:cancelTarget,p_motivo:reason,p_token:token}):await supabase.rpc("estornar_venda",{p_venda_id:cancelTarget,p_motivo:reason,p_token:token});if(e)throw e;setModal("");setCancelTarget("");setManagerPin("");setReason("");if(cancelType==="item")await refresh();}catch(err){setError(erro(err));}}
async function applyDiscount(){if(!cartId)return;try{const token=await autorizar("desconto_manual");const {data,error:e}=await supabase.rpc("aplicar_desconto_carrinho",{p_carrinho_id:cartId,p_tipo:discountType,p_valor:Number(discountValue),p_token:token,p_motivo:reason});if(e)throw e;setDiscount(Number(data));setModal("");setManagerPin("");setReason("");setDiscountValue("");}catch(err){setError(erro(err));}}
 useEffect(()=>{const handler=(e:KeyboardEvent)=>{
   const el=e.target as HTMLElement; const k=e.key; const lk=k.toLowerCase();
   // Campo de bipagem vazio não conta como digitação: as teclas de atalho funcionam a partir dele.
   const typing=(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement||el instanceof HTMLSelectElement)&&!(el===codeRef.current&&code==="");
   if(k==="Escape"){e.preventDefault(); if(helpOpen){setHelpOpen(false);return;} if(checkout){setCheckout(false);return;} if(modal){setModal("");return;} return;}
   if((receipt||zreport)&&k==="Enter"){e.preventDefault();window.print();return;}
   if(receipt&&k==="F10"){e.preventDefault();setReceiptMode("troca");setTimeout(()=>window.print(),100);return;}
   if(!typing&&lk==="x"){e.preventDefault();setHelpOpen(v=>!v);return;}
   if(k==="F1"){e.preventDefault();setCalcExpr("");setModal("calc");return;}
   if(k==="F2"||k==="F3"){e.preventDefault();void lockOperator();return;}
   if(k==="F4"){e.preventDefault();payWith("debito");return;}
   if(k==="F5"){e.preventDefault();payWith("credito");return;}
   if(k==="F6"){e.preventDefault();payWith("dinheiro");return;}
   if(k==="F7"){e.preventDefault();payWith("pos");return;}
   if(k==="F8"){e.preventDefault();setError("PIX ainda não disponível.");return;}
   if(k==="F9"){e.preventDefault();setPriceQuery("");setPriceResult(null);setModal("price");return;}
   if(k==="End"&&!typing){e.preventDefault();setModal("discount");return;}
   if(k==="Delete"&&!typing){e.preventDefault();if(rows.length)setModal("cancel");return;}
   if(k==="Insert"&&!typing){e.preventDefault();setError("Vendedor ainda não disponível.");return;}
   if(k==="PageDown"&&!typing){e.preventDefault();setError("Alterar preço ainda não disponível.");return;}
   if(!typing){
     if(lk==="w"){e.preventDefault();setModal("recover");return;}
     if(lk==="t"){e.preventDefault();setModal("trade");return;}
     if(lk==="z"){e.preventDefault();setModal("z");return;}
     if(lk==="g"){e.preventDefault();setModal("sangria");return;}
     if(lk==="r"){e.preventDefault();setError("Devolução ainda não disponível.");return;}
     if(lk==="d"){e.preventDefault();setError("Cupom de desconto ainda não disponível.");return;}
     if(k===" "){e.preventDefault();if(rows.length)setCheckout(true);return;}
   }
 };window.addEventListener("keydown",handler);return()=>window.removeEventListener("keydown",handler);},[checkout,cartId,rows,pdv,op,modal,receipt,zreport,code,helpOpen]);
 const accent = tenantBrand.cor_primaria === "#0f172a" ? "#4f46e5" : tenantBrand.cor_primaria;
 const cls = {
  field: "w-full rounded-lg border border-slate-800 bg-slate-950/80 px-3 py-2.5 text-sm text-slate-100 placeholder:text-slate-500 outline-none transition focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent)]/30",
  primary: "inline-flex items-center justify-center gap-2 rounded-lg bg-[var(--accent)] px-4 py-2.5 font-semibold text-white transition hover:brightness-110 disabled:opacity-40",
  ghost: "inline-flex items-center gap-2 rounded-lg border border-slate-800 bg-slate-900/70 px-3 py-2 text-sm text-slate-300 transition hover:border-slate-700 hover:text-slate-100 disabled:opacity-40",
  amber: "inline-flex items-center justify-center gap-2 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-2.5 text-sm font-semibold text-amber-400 transition hover:bg-amber-500/20",
  emerald: "inline-flex w-full items-center justify-center gap-2 rounded-lg bg-emerald-500 px-4 py-3.5 text-base font-bold text-slate-950 shadow-lg shadow-emerald-500/20 transition hover:bg-emerald-400 disabled:opacity-40 disabled:shadow-none",
  kbd: "rounded border border-slate-700 bg-slate-800 px-1.5 py-0.5 font-mono text-[11px] text-slate-300",
  panel: "rounded-2xl border border-slate-800/80 bg-slate-900/90 shadow-2xl backdrop-blur-md",
 };
 if(!op)return <main style={{"--accent":accent} as React.CSSProperties} className="min-h-screen grid place-items-center bg-slate-950 p-4 text-slate-100"><form action={login} className={`${cls.panel} w-full max-w-sm space-y-4 p-6`}><TenantBrandMark/><div><h1 className="text-xl font-semibold">Acesso ao caixa</h1><p className="text-sm text-slate-400">Entre com a chapa e a senha de 6 dígitos.</p></div><label className="block space-y-1.5 text-sm text-slate-300">Código da loja<input name="storeCode" value={storeAccessCode} onChange={e=>setStoreAccessCode(e.target.value.toUpperCase())} required maxLength={12} autoCapitalize="characters" className={cls.field}/></label><label className="block space-y-1.5 text-sm text-slate-300">Chapa<input name="chapa" required autoFocus className={cls.field}/></label><label className="block space-y-1.5 text-sm text-slate-300">Senha de 6 dígitos<input name="pin" required inputMode="numeric" pattern="[0-9]{6}" type="password" className={cls.field}/></label><label className="block space-y-1.5 text-sm text-slate-300">Código do PDV<input value={pdv} onChange={e=>setPdv(e.target.value)} className={cls.field}/></label><button className={`${cls.primary} w-full`}>Entrar</button>{error&&<p className="text-sm text-red-400">{error}</p>}</form></main>;

 const filtrados = catalog.filter(v=>{const q=filtro.trim().toLowerCase();if(!q)return true;return [v.produto?.nome,v.sku,v.codigo_barras,v.cor,v.tamanho].some(x=>String(x||"").toLowerCase().includes(q));});
 const a_pagar = Math.max(0,total-credit-discount);
 const hora = agora.toLocaleTimeString("pt-BR",{hour:"2-digit",minute:"2-digit"});
 const data = agora.toLocaleDateString("pt-BR",{day:"2-digit",month:"short"});

 return <main style={{"--accent":accent} as React.CSSProperties} className="flex h-screen flex-col overflow-hidden bg-slate-950 text-slate-100">
  <header className="no-print flex flex-wrap items-center gap-3 border-b border-slate-800/80 bg-slate-900/90 px-4 py-3 backdrop-blur-md lg:px-6">
   <div className="flex min-w-0 items-center gap-3">
    <TenantBrandMark compact />
    <div className="min-w-0">
     <div className="flex items-center gap-2">
      <h1 className="truncate text-sm font-semibold">{tenantBrand.nome_fantasia}</h1>
      <span className="inline-flex items-center gap-1.5 rounded-full bg-emerald-500/10 px-2 py-0.5 text-[11px] font-medium text-emerald-400 ring-1 ring-emerald-500/30">
       <span className="relative flex h-1.5 w-1.5"><span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75"/><span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-emerald-400"/></span>
       Caixa {pdv} • {online?"Online":"Offline"}
      </span>
     </div>
     <p className="truncate text-xs text-slate-400">{op.nome} · {op.chapa} · {op.cargo}</p>
    </div>
   </div>

   <div className="order-last flex w-full items-center gap-2 lg:order-none lg:mx-auto lg:w-auto lg:flex-1 lg:max-w-xl">
    <div className="relative flex-1">
     <input ref={codeRef} autoFocus value={code} onChange={e=>setCode(e.target.value)} onKeyDown={e=>e.key==="Enter"&&void scan()} placeholder="Buscar SKU, nome ou código de barras" className={`${cls.field} py-2.5 pl-3 pr-16`}/>
     <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2"></span>
    </div>
    <button onClick={()=>void scan()} className={cls.primary}>Buscar</button>
   </div>

   <div className="ml-auto flex flex-wrap items-center gap-2">
    <span className="hidden text-xs text-slate-400 xl:inline">{data} · {hora}</span>
    <button onClick={()=>setModal("fund")} className={cls.ghost}>Abrir caixa</button>
    <button onClick={()=>setModal("sangria")} className={cls.ghost}>Sangria</button>
    <button onClick={()=>setModal("z")} className={cls.ghost}>Fechamento</button>
    <button onClick={()=>void lockOperator()} className={cls.ghost}>Sair</button>
    <a href="/admin/identidade" className={cls.ghost}>Identidade</a>
   </div>
  </header>

  <div className="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[minmax(0,1.85fr)_minmax(340px,1fr)]">
   <section className="no-print flex min-h-0 flex-col gap-4 p-4 lg:p-6">
    <div className="flex items-center justify-between gap-3">
     <div>
      <h2 className="text-lg font-semibold">Produtos</h2>
      <p className="text-xs text-slate-400">{filtrados.length} de {catalog.length} variações</p>
     </div>
     <input value={filtro} onChange={e=>setFiltro(e.target.value)} placeholder="Filtrar catálogo" className={`${cls.field} max-w-xs`}/>
    </div>

    {!cartId&&<p className="rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 py-2 text-sm text-amber-300">Nenhuma venda aberta. Os produtos ficam disponíveis assim que a venda começar.</p>}

    {catalog.length===0?
     <div className="grid flex-1 place-items-center rounded-2xl border border-dashed border-slate-800 p-10 text-center">
      <div><p className="font-medium text-slate-200">Nenhum produto cadastrado nesta loja</p><p className="mt-1 text-sm text-slate-400">Cadastre os produtos e variações para vê-los aqui.</p></div>
     </div>
    :
     <div className="grid min-h-0 flex-1 auto-rows-max grid-cols-2 content-start gap-3 overflow-y-auto pr-1 sm:grid-cols-3 2xl:grid-cols-4">
      {filtrados.map(v=><button key={v.id} onClick={()=>void scan(v.codigo_barras||v.sku)} disabled={!cartId} className={`${cls.panel} group flex flex-col overflow-hidden text-left transition hover:border-[var(--accent)]/60 disabled:cursor-not-allowed disabled:opacity-50`}>
       <div className="grid aspect-[4/3] place-items-center bg-gradient-to-br from-slate-800 to-slate-900 text-slate-500 transition group-hover:from-slate-700/70"><span className="text-xs">{v.cor}</span></div>
       <div className="flex flex-1 flex-col gap-1 p-3">
        <p className="line-clamp-1 text-sm font-medium text-slate-100">{v.produto?.nome}</p>
        <p className="truncate text-[11px] text-slate-500">SKU {v.sku}</p>
        <div className="mt-auto flex items-end justify-between pt-2">
         <span className="rounded bg-slate-800 px-1.5 py-0.5 text-[11px] font-medium text-slate-300">{v.tamanho}</span>
         <span className="text-sm font-semibold tabular-nums text-emerald-400">{brl(v.preco)}</span>
        </div>
        <p className={`text-[11px] ${Number(v.estoque)>0?"text-slate-500":"text-red-400"}`}>{Number(v.estoque)>0?`${v.estoque} em estoque`:"Sem estoque"}</p>
       </div>
      </button>)}
     </div>}
   </section>

   <aside className="no-print flex min-h-0 flex-col border-t border-slate-800/80 bg-slate-900/60 lg:border-l lg:border-t-0">
    <div className="flex items-center justify-between border-b border-slate-800/80 px-5 py-4">
     <h2 className="font-semibold">Resumo da venda</h2>
     <span className="text-xs text-slate-400">{rows.reduce((a,r)=>a+r.quantidade,0)} itens</span>
    </div>

    <div className="border-b border-slate-800/80 px-5 py-3">
     <input value={cpf} onChange={e=>void findClient(e.target.value)} inputMode="numeric" placeholder="CPF do cliente (opcional)" className={cls.field}/>
     {client.nome&&<p className="mt-2 text-xs text-slate-400">{client.nome}{client.email?` · ${client.email}`:""}</p>}
    </div>

    <div className="min-h-0 flex-1 overflow-y-auto px-5 py-3">
     {!cartId&&<button onClick={()=>void start()} disabled={!op} className={`${cls.primary} w-full`}>Iniciar venda</button>}
     {cartId&&rows.length===0&&
      <div className="space-y-4">
       <div className="grid place-items-center rounded-xl border border-dashed border-slate-800 p-8 text-center">
        <p className="font-medium text-slate-200">Aguardando leitura do próximo item</p>
        <p className="mt-1 text-xs text-slate-500">Bipe o código de barras ou escolha um produto ao lado.</p>
       </div>
       {ultimaVenda&&<div className="rounded-xl border border-slate-800 bg-slate-950/60 p-4">
        <p className="text-xs text-slate-400">Última venda</p>
        <p className="mt-1 text-lg font-semibold tabular-nums">{brl(ultimaVenda.venda?.total ?? 0)}</p>
        <button onClick={()=>setReceipt(ultimaVenda)} className={`${cls.ghost} mt-3 w-full justify-center`}>Reimprimir cupom</button>
       </div>}
      </div>}
     {rows.map(i=><div key={i.id} className="flex items-start justify-between gap-3 border-b border-slate-800/60 py-3">
      <div className="min-w-0">
       <p className="truncate text-sm font-medium text-slate-100">{i.variacao.produto.nome}</p>
       <p className="text-xs text-slate-500">{i.variacao.cor} · {i.variacao.tamanho} · SKU {i.variacao.sku}</p>
       <p className="mt-1 text-xs text-slate-400">{i.quantidade} × {brl(i.variacao.preco)}</p>
      </div>
      <b className="shrink-0 text-sm tabular-nums">{brl(i.variacao.preco*i.quantidade)}</b>
     </div>)}
    </div>

    <div className="space-y-2 border-t border-slate-800/80 px-5 py-4 text-sm">
     <div className="flex justify-between text-slate-400"><span>Subtotal</span><span className="tabular-nums">{brl(total)}</span></div>
     {discount>0&&<div className="flex justify-between text-slate-400"><span>Desconto autorizado</span><span className="tabular-nums text-amber-400">-{brl(discount)}</span></div>}
     {credit>0&&<div className="flex justify-between text-slate-400"><span>Crédito troca</span><span className="tabular-nums text-amber-400">-{brl(credit)}</span></div>}
     <div className="flex items-end justify-between pt-2"><span className="font-medium text-slate-300">Total</span><span className="text-3xl font-bold tabular-nums">{brl(a_pagar)}</span></div>
     {error&&<p role="alert" className="pt-1 text-sm text-red-400">{error}</p>}
    </div>

    <div className="grid grid-cols-3 gap-2 px-5 pb-3">
     <button onClick={()=>setModal("trade")} className={cls.amber}>Troca</button>
     <button onClick={()=>setModal("discount")} disabled={!rows.length} className={`${cls.ghost} justify-center`}>Desconto</button>
     <button onClick={()=>setModal("cancel")} disabled={!rows.length} className={`${cls.ghost} justify-center`}>Cancelar</button>
    </div>
    <div className="px-5 pb-5">
     <button onClick={()=>rows.length&&setCheckout(true)} disabled={!rows.length} className={cls.emerald}>Finalizar venda · {brl(a_pagar)}</button>
    </div>
   </aside>
  </div>



  {checkout&&<div className="no-print fixed inset-0 z-40 grid place-items-center bg-slate-950/70 p-4 backdrop-blur-sm"><section className={`${cls.panel} w-full max-w-lg space-y-4 p-5`}>
   <div><h2 className="text-lg font-semibold">Pagamento</h2><p className="text-3xl font-bold tabular-nums">{brl(a_pagar)}</p></div>
   <div className="grid grid-cols-5 gap-2">{[["debito","Débito"],["credito","Crédito"],["dinheiro","Dinheiro"],["pos","POS"],["pix","PIX"]].map(([id,label])=><button key={id} disabled={id==="pix"} onClick={()=>{setPay(id);if(id==="pos")setModal("pos");}} className={`rounded-lg border px-2 py-2.5 text-sm transition ${pay===id?"border-[var(--accent)] bg-[var(--accent)]/20 text-white":"border-slate-800 text-slate-300 hover:border-slate-700"}`}>{label}</button>)}</div>
   {pay==="dinheiro"&&<label className="block space-y-1.5 text-sm text-slate-300">Valor recebido<input value={cash} onChange={e=>setCash(e.target.value)} type="number" step="0.01" className={cls.field}/><span className="block text-xs text-slate-400">Troco: <b className="tabular-nums text-slate-200">{brl(Math.max(0,Number(cash)-a_pagar))}</b></span></label>}
   <label className="block space-y-1.5 text-sm text-slate-300">CPF do cliente<input value={cpf} onChange={e=>void findClient(e.target.value)} className={cls.field} inputMode="numeric"/></label>
   {cpf.length===11&&<div className="grid grid-cols-2 gap-2"><input value={client.nome} onChange={e=>setClient({...client,nome:e.target.value})} placeholder="Nome" className={cls.field}/><input value={client.email} onChange={e=>setClient({...client,email:e.target.value})} placeholder="E-mail" className={cls.field}/></div>}
   <div className="flex gap-2"><button onClick={()=>setCheckout(false)} className={cls.ghost}>Voltar</button><button onClick={()=>void complete()} className={`${cls.emerald} flex-1`}>Concluir venda</button></div>
   {error&&<p className="text-sm text-red-400">{error}</p>}
  </section></div>}

  {modal&&<div className="no-print fixed inset-0 z-40 grid place-items-center bg-slate-950/70 p-4 backdrop-blur-sm"><section className={`${cls.panel} w-full max-w-md space-y-3 p-5`}>
   <div className="flex items-start justify-between gap-4"><h2 className="font-semibold">{({recover:"Recuperar pedido",trade:"Troca de mercadoria",z:"Fechamento Z — autorização",fund:"Abertura de caixa — fundo de troco",sangria:"Sangria — autorização de liderança",pos:"Dados da maquininha POS",cancel:"Cancelamento protegido",discount:"Desconto manual protegido",calc:"Calculadora",price:"Consultar preço"} as Record<string,string>)[modal]}</h2><button onClick={()=>setModal("")} className="text-slate-400 hover:text-slate-100" aria-label="Fechar">✕</button></div>
   {modal==="recover"&&<Recover onChoose={async id=>{setCartId(id);setCheckout(false);setModal("");await refresh(id);}}/>}
   {modal==="calc"&&<><input value={calcExpr} onChange={e=>setCalcExpr(e.target.value)} onKeyDown={e=>{if(e.key==="Enter"){e.preventDefault();const r=calcEval(calcExpr);if(r!==null)setCalcExpr(String(r));}}} placeholder="Ex.: 12,5*3+10" className={`${cls.field} text-right text-xl tabular-nums`}/><div className="grid grid-cols-4 gap-2">{["7","8","9","/","4","5","6","*","1","2","3","-","0",".","C","+"].map(t=><button key={t} onClick={()=>setCalcExpr(t==="C"?"":calcExpr+t)} className={`${cls.ghost} justify-center py-3 text-base`}>{t}</button>)}<button onClick={()=>{const r=calcEval(calcExpr);if(r!==null)setCalcExpr(String(r));}} className={`${cls.primary} col-span-4 justify-center`}>=</button></div></>}
   {modal==="price"&&<><div className="flex gap-2"><input value={priceQuery} onChange={e=>setPriceQuery(e.target.value)} onKeyDown={e=>{if(e.key==="Enter")void consultPrice();}} placeholder="Código de barras ou SKU" autoFocus className={cls.field}/><button onClick={()=>void consultPrice()} className={cls.primary}>Consultar</button></div>{priceResult==="nao"&&<p className="text-sm text-red-400">Produto não encontrado.</p>}{priceResult&&priceResult!=="nao"&&<div className="rounded-xl border border-slate-800 bg-slate-950/60 p-4"><p className="font-medium">{priceResult.produto?.nome}</p><p className="text-xs text-slate-400">{priceResult.cor} · {priceResult.tamanho} · SKU {priceResult.sku}</p><p className="mt-2 text-2xl font-bold tabular-nums text-emerald-400">{brl(priceResult.preco)}</p><p className="text-xs text-slate-400">{Number(priceResult.estoque)>0?`${priceResult.estoque} em estoque`:"Sem estoque"}</p></div>}</>}
   {modal==="trade"&&<><input value={returnCode} onChange={e=>setReturnCode(e.target.value)} placeholder="Código/SKU devolvido" className={cls.field}/><input value={returnNf} onChange={e=>setReturnNf(e.target.value)} placeholder="Número da Nota Fiscal" className={cls.field}/><input value={returnValue} onChange={e=>setReturnValue(e.target.value)} placeholder="Valor de crédito" type="number" step="0.01" className={cls.field}/><button onClick={()=>void addReturn()} className={`${cls.primary} w-full`}>Adicionar troca ao pedido</button></>}
   {modal==="z"&&<><p className="text-sm text-slate-400">Líder, supervisor ou gerente autoriza o encerramento e fica registrado no Z.</p><input value={managerChapa} onChange={e=>setManagerChapa(e.target.value)} placeholder="Chapa da liderança" className={cls.field}/><input value={managerPin} onChange={e=>setManagerPin(e.target.value)} placeholder="Senha de 6 dígitos" type="password" className={cls.field}/><input value={reason} onChange={e=>setReason(e.target.value)} placeholder="Motivo do fechamento" className={cls.field}/><button onClick={()=>void closeZ()} className={`${cls.primary} w-full`}>Autorizar e fechar dia</button></>}
   {modal==="fund"&&<><p className="text-sm text-slate-400">Abertura antes da primeira venda do dia. Exige liderança.</p><input value={fund} onChange={e=>setFund(e.target.value)} placeholder="Fundo de troco" type="number" step="0.01" className={cls.field}/><input value={managerChapa} onChange={e=>setManagerChapa(e.target.value)} placeholder="Chapa da liderança" className={cls.field}/><input value={managerPin} onChange={e=>setManagerPin(e.target.value)} placeholder="Senha de 6 dígitos" type="password" className={cls.field}/><input value={reason} onChange={e=>setReason(e.target.value)} placeholder="Motivo da abertura" className={cls.field}/><button onClick={()=>void openTill()} className={`${cls.primary} w-full`}>Abrir caixa</button></>}
   {modal==="sangria"&&<><input value={withdraw} onChange={e=>setWithdraw(e.target.value)} placeholder="Valor da retirada" type="number" step="0.01" className={cls.field}/><input value={managerChapa} onChange={e=>setManagerChapa(e.target.value)} placeholder="Chapa da liderança" className={cls.field}/><input value={managerPin} onChange={e=>setManagerPin(e.target.value)} placeholder="Senha de 6 dígitos" type="password" className={cls.field}/><input value={reason} onChange={e=>setReason(e.target.value)} placeholder="Motivo da sangria" className={cls.field}/><button onClick={()=>void sangria()} className={`${cls.primary} w-full`}>Registrar sangria</button></>}
   {modal==="pos"&&<><select value={brand} onChange={e=>setBrand(e.target.value)} className={cls.field}>{["visa","mastercard","elo","amex","hipercard","pix"].map(b=><option key={b}>{b}</option>)}</select><label className="block space-y-1.5 text-sm text-slate-300">Data da transação<input type="date" value={posDate} onChange={e=>setPosDate(e.target.value)} className={cls.field}/></label><label className="block space-y-1.5 text-sm text-slate-300">Código/NSU<input value={nsu} onChange={e=>setNsu(e.target.value)} className={cls.field}/></label><button onClick={()=>setModal("")} className={`${cls.primary} w-full`}>Salvar dados POS</button></>}
   {modal==="cancel"&&<><select value={cancelType} onChange={e=>setCancelType(e.target.value)} className={cls.field}><option value="item">Cancelar item do carrinho</option><option value="sale">Estornar venda concluída</option></select>{cancelType==="item"?<select value={cancelTarget} onChange={e=>setCancelTarget(e.target.value)} className={cls.field}><option value="">Selecione o item</option>{rows.map(r=><option key={r.id} value={r.id}>{r.variacao.produto.nome} {r.variacao.cor}/{r.variacao.tamanho} · {r.quantidade}</option>)}</select>:<input value={cancelTarget} onChange={e=>setCancelTarget(e.target.value)} placeholder="ID da venda" className={cls.field}/>}<input value={managerChapa} onChange={e=>setManagerChapa(e.target.value)} placeholder="Chapa da liderança" className={cls.field}/><input value={managerPin} onChange={e=>setManagerPin(e.target.value)} placeholder="Senha de 6 dígitos" type="password" className={cls.field}/><input value={reason} onChange={e=>setReason(e.target.value)} placeholder="Motivo do cancelamento/estorno" className={cls.field}/><button onClick={()=>void cancel()} className="w-full rounded-lg bg-red-600 px-4 py-2.5 font-semibold text-white hover:bg-red-500">Autorizar cancelamento</button></>}
   {modal==="discount"&&<><p className="text-sm text-slate-400">O desconto exige autorização e fica registrado no relatório Z.</p><select value={discountType} onChange={e=>setDiscountType(e.target.value)} className={cls.field}><option value="valor">Valor em R$</option><option value="percentual">Percentual %</option></select><input value={discountValue} onChange={e=>setDiscountValue(e.target.value)} type="number" min="0.01" step="0.01" placeholder="Desconto" className={cls.field}/><input value={managerChapa} onChange={e=>setManagerChapa(e.target.value)} placeholder="Chapa da liderança" className={cls.field}/><input value={managerPin} onChange={e=>setManagerPin(e.target.value)} placeholder="Senha de 6 dígitos" type="password" className={cls.field}/><input value={reason} onChange={e=>setReason(e.target.value)} placeholder="Motivo do desconto" className={cls.field}/><button onClick={()=>void applyDiscount()} className={`${cls.primary} w-full`}>Validar e aplicar</button></>}
   {error&&<p className="text-sm text-red-400">{error}</p>}
  </section></div>}

  {receipt&&<div className="receipt-overlay"><div className="no-print rounded-2xl border border-slate-800 bg-slate-900 p-4 text-slate-100 shadow-2xl"><div className="mb-3 flex flex-wrap gap-2"><button autoFocus onClick={()=>window.print()} className={cls.primary}>Imprimir venda</button><button onClick={()=>{setReceiptMode("troca");setTimeout(()=>window.print(),100);}} className={cls.ghost}>Cupom de troca sem preços</button><button onClick={()=>setReceipt(null)} className={cls.ghost}>Fechar</button></div><BobinaTermica venda={receipt}/></div><div className="print-only"><BobinaTermica venda={receipt} troca={receiptMode==="troca"}/></div></div>}
  {zreport&&<div className="receipt-overlay"><div className="no-print rounded-2xl border border-slate-800 bg-slate-900 p-4 text-slate-100 shadow-2xl"><div className="mb-3 flex gap-2"><button autoFocus onClick={()=>window.print()} className={cls.primary}>Imprimir Relatório Z</button><button onClick={()=>setZreport(null)} className={cls.ghost}>Fechar</button></div><BobinaTermica relatorio={zreport}/></div><div className="print-only"><BobinaTermica relatorio={zreport}/></div></div>}
  {helpOpen&&<div className="no-print fixed inset-0 z-50 grid place-items-center bg-slate-950/70 p-4 backdrop-blur-sm" onClick={()=>setHelpOpen(false)}><section onClick={e=>e.stopPropagation()} className={`${cls.panel} w-full max-w-lg space-y-3 p-5`}>
   <div className="flex items-center justify-between"><h2 className="font-semibold">Teclas do caixa</h2><button onClick={()=>setHelpOpen(false)} className="text-slate-400 hover:text-slate-100" aria-label="Fechar">✕</button></div>
   <table className="w-full text-sm"><tbody>
    {HELP_KEYS.map(([tecla,funcao,estado])=><tr key={tecla} className="border-b border-slate-800/60"><td className="py-2 pr-3 align-top"><kbd className={cls.kbd}>{tecla}</kbd></td><td className="py-2 text-slate-200">{funcao}{estado&&<span className="ml-2 rounded bg-slate-800 px-1.5 py-0.5 text-[11px] text-slate-400">{estado}</span>}</td></tr>)}
   </tbody></table>
   <p className="text-xs text-slate-500">Pressione X de novo ou Esc para fechar.</p>
  </section></div>}
 </main>;
}

function Recover({onChoose}:{onChoose:(id:string)=>void}){const [list,setList]=useState<any[]>([]);const [error,setError]=useState("");useEffect(()=>{void supabase.from("carrinhos_ativos").select("id,updated_at,operador:operadores(chapa,nome),itens:carrinho_itens(quantidade)").eq("status","aberto").order("updated_at",{ascending:false}).then(({data,error:e})=>{if(e)setError(e.message);else setList(data||[]);});},[]);return <div>{list.map(c=><button key={c.id} onClick={()=>onChoose(c.id)} className="w-full border-b p-3 text-left">{c.operador?.chapa} · {c.operador?.nome} · {c.itens?.reduce((a:number,i:any)=>a+i.quantidade,0)} itens · {new Date(c.updated_at).toLocaleTimeString("pt-BR")}</button>)}{error&&<p className="text-red-700">{error}</p>}</div>;}
