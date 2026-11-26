"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import { Store, LogOut, RefreshCw, UserRoundPlus } from "lucide-react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";

type StoreRow = { id: string; codigo_acesso: string; nome_fantasia: string; cnpj: string; created_at: string };
type Credentials = { loja: string; codigoAcesso: string; gerente: string; chapa: string; pin: string; pdv: string };

export default function LojasAdminPage() {
  const [session, setSession] = useState<Session | null>(null);
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [credentials, setCredentials] = useState<Credentials | null>(null);

  const loadStores = useCallback(async (token: string) => {
    const response = await fetch("/api/admin/lojas", { headers: { Authorization: `Bearer ${token}` }, cache: "no-store" });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Não foi possível carregar as lojas.");
    setStores(result.lojas || []);
  }, []);

  useEffect(() => {
    let alive = true;
    void supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return;
      setSession(data.session);
      if (data.session) {
        try { await loadStores(data.session.access_token); }
        catch (e) { setError(e instanceof Error ? e.message : "Falha ao carregar lojas."); }
      }
      if (alive) setLoading(false);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
      if (next) void loadStores(next.access_token).catch((e) => setError(e instanceof Error ? e.message : "Falha ao carregar lojas."));
      else setStores([]);
    });
    return () => { alive = false; listener.subscription.unsubscribe(); };
  }, [loadStores]);

  async function signIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setError(""); setBusy(true);
    const form = new FormData(event.currentTarget);
    const { data, error: authError } = await supabase.auth.signInWithPassword({ email: String(form.get("email") || "").trim(), password: String(form.get("password") || "") });
    setBusy(false);
    if (authError) setError("E-mail ou senha administrativa inválidos.");
    else if (data.session) {
      try { await loadStores(data.session.access_token); } catch (e) { setError(e instanceof Error ? e.message : "Falha ao carregar lojas."); }
    }
  }

  async function createStore(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!session) return;
    const formElement = event.currentTarget;
    setError(""); setNotice(""); setCredentials(null); setBusy(true);
    const form = new FormData(formElement);
    const payload = Object.fromEntries(form.entries());
    const response = await fetch("/api/admin/lojas", { method: "POST", headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    const result = await response.json();
    setBusy(false);
    if (!response.ok) { setError(result.error || "Não foi possível cadastrar a loja."); return; }
    setCredentials({ loja: String(payload.nomeFantasia), codigoAcesso: String(result.loja?.codigo_acesso || ""), gerente: String(payload.gerenteNome), chapa: String(payload.gerenteChapa), pin: String(payload.gerentePin), pdv: String(payload.pdvCodigo) });
    setNotice("Loja cadastrada. Guarde e entregue o acesso ao gerente por um canal seguro.");
    formElement.reset();
    try { await loadStores(session.access_token); } catch (e) { setError(e instanceof Error ? e.message : "Loja criada, mas a lista não atualizou."); }
  }

  async function signOut() { await supabase.auth.signOut(); setCredentials(null); setStores([]); }

  if (loading) return <main className="min-h-screen grid place-items-center">Carregando área administrativa…</main>;

  if (!session) return <main className="min-h-screen grid place-items-center p-4"><form onSubmit={signIn} className="w-full max-w-md rounded-2xl bg-white p-6 shadow space-y-4"><div className="flex items-center gap-3"><Store className="text-emerald-700"/><div><h1 className="text-2xl font-bold">Administração da plataforma</h1><p className="text-sm text-slate-600">Entre com o e-mail administrativo configurado no servidor.</p></div></div><label className="block">E-mail<input name="email" type="email" autoComplete="username" required className="mt-1 block w-full rounded border p-3"/></label><label className="block">Senha<input name="password" type="password" autoComplete="current-password" required className="mt-1 block w-full rounded border p-3"/></label>{error&&<p role="alert" className="text-sm text-red-700">{error}</p>}<button disabled={busy} className="w-full rounded bg-emerald-700 p-3 font-semibold text-white disabled:opacity-50">{busy?"Entrando…":"Entrar"}</button><p className="text-xs text-slate-500">Esta área é exclusiva da administração do produto. O acesso do gerente da loja é criado depois do cadastro.</p></form></main>;

  return <main className="min-h-screen p-4 md:p-8"><div className="mx-auto max-w-6xl space-y-6"><header className="flex flex-wrap items-center justify-between gap-3"><div><p className="text-sm font-semibold uppercase tracking-wide text-emerald-700">Painel da plataforma</p><h1 className="text-3xl font-bold">Lojas clientes</h1><p className="text-slate-600">Cadastre uma loja, o primeiro caixa e o gerente responsável.</p></div><button onClick={()=>void signOut()} className="inline-flex items-center gap-2 rounded border bg-white px-4 py-2"><LogOut size={17}/> Sair</button></header>

    {error&&<p role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-red-800">{error}</p>}
    {notice&&<p role="status" className="rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-emerald-900">{notice}</p>}
    {credentials&&<section className="rounded-xl border border-emerald-300 bg-white p-5"><h2 className="font-bold">Acesso inicial do cliente</h2><p className="mt-2">Loja: <strong>{credentials.loja}</strong> · Código da loja: <strong>{credentials.codigoAcesso}</strong></p><p>Gerente: <strong>{credentials.gerente}</strong> · Matrícula: <strong>{credentials.chapa}</strong> · PIN inicial: <strong>{credentials.pin}</strong></p><p>Caixa inicial: <strong>{credentials.pdv}</strong></p><p className="mt-2 text-sm text-slate-600">O gerente entra em <code>/caixa</code>. Compartilhe o código da loja e o PIN apenas diretamente com ele.</p></section>}

    <div className="grid gap-6 lg:grid-cols-[1.3fr_0.9fr]"><form onSubmit={createStore} className="space-y-4 rounded-2xl bg-white p-5 shadow-sm"><div className="flex items-center gap-2"><UserRoundPlus className="text-emerald-700"/><h2 className="text-xl font-bold">Cadastrar cliente</h2></div><div className="grid gap-3 sm:grid-cols-2"><label className="block sm:col-span-2">Nome da loja<input name="nomeFantasia" required maxLength={120} className="mt-1 block w-full rounded border p-3"/></label><label className="block">CNPJ<input name="cnpj" required inputMode="numeric" maxLength={18} placeholder="00.000.000/0000-00" className="mt-1 block w-full rounded border p-3"/></label><label className="block">Telefone<input name="telefone" maxLength={40} className="mt-1 block w-full rounded border p-3"/></label><label className="block sm:col-span-2">Endereço<input name="endereco" maxLength={240} className="mt-1 block w-full rounded border p-3"/></label><label className="block">Código do primeiro caixa<input name="pdvCodigo" required maxLength={20} defaultValue="001" className="mt-1 block w-full rounded border p-3"/></label><label className="block">Nome do caixa<input name="pdvNome" required maxLength={80} defaultValue="Caixa principal" className="mt-1 block w-full rounded border p-3"/></label><label className="block">Nome do gerente<input name="gerenteNome" required maxLength={120} className="mt-1 block w-full rounded border p-3"/></label><label className="block">CPF do gerente<input name="gerenteCpf" required inputMode="numeric" maxLength={14} placeholder="000.000.000-00" className="mt-1 block w-full rounded border p-3"/></label><label className="block">Matrícula do gerente<input name="gerenteChapa" required maxLength={20} className="mt-1 block w-full rounded border p-3"/></label><label className="block">PIN inicial (6 dígitos)<input name="gerentePin" required inputMode="numeric" pattern="[0-9]{6}" minLength={6} maxLength={6} type="password" className="mt-1 block w-full rounded border p-3"/></label></div><p className="text-xs text-slate-500">O gerente poderá entrar no caixa com chapa e PIN. Configure um PIN inicial exclusivo e entregue diretamente ao responsável.</p><button disabled={busy} className="inline-flex items-center gap-2 rounded bg-emerald-700 px-5 py-3 font-semibold text-white disabled:opacity-50"><UserRoundPlus size={17}/>{busy?"Cadastrando…":"Cadastrar loja"}</button></form>

    <section className="rounded-2xl bg-white p-5 shadow-sm"><div className="flex items-center justify-between gap-2"><h2 className="text-xl font-bold">Clientes cadastrados</h2><button onClick={()=>session&&void loadStores(session.access_token).catch(e=>setError(e.message))} className="rounded border p-2" aria-label="Atualizar lista"><RefreshCw size={17}/></button></div>{stores.length===0?<p className="mt-4 text-sm text-slate-500">Nenhuma loja cadastrada ainda.</p>:<ul className="mt-3 divide-y">{stores.map(store=><li key={store.id} className="py-3"><strong>{store.nome_fantasia}</strong><p className="text-sm text-slate-600">Código: {store.codigo_acesso} · CNPJ {store.cnpj} · {new Date(store.created_at).toLocaleDateString("pt-BR")}</p></li>)}</ul>}</section></div>
  </div></main>;
}
