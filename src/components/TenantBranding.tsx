"use client";
import { createContext, useContext, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

export type TenantBrand = { loja_id: string; nome_fantasia: string; logo_url: string | null; cor_primaria: string; cor_secundaria: string };
const defaultBrand: TenantBrand = { loja_id: "", nome_fantasia: "PDV", logo_url: null, cor_primaria: "#0f172a", cor_secundaria: "#334155" };
const BrandContext = createContext<{ brand: TenantBrand; ready: boolean }>({ brand: defaultBrand, ready: false });

export function TenantBrandingProvider({ children }: { children: React.ReactNode }) {
  const [brand, setBrand] = useState(defaultBrand);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let live = true;
    let channel: ReturnType<typeof supabase.channel> | null = null;
    async function load(session: { user: { id: string } } | null) {
      if (!session) {
        if (channel) void supabase.removeChannel(channel);
        channel = null;
        if (live) { setBrand(defaultBrand); setReady(true); }
        return;
      }
      const { data, error } = await supabase.rpc("minha_identidade_loja");
      const row = (Array.isArray(data) ? data[0] : data) as TenantBrand | null;
      if (!live || error || !row) { if (live) setReady(true); return; }
      setBrand(row);
      setReady(true);
      if (channel) void supabase.removeChannel(channel);
      channel = supabase.channel(`tenant-brand-${row.loja_id}`).on("postgres_changes", { event: "UPDATE", schema: "public", table: "lojas", filter: `id=eq.${row.loja_id}` }, () => { void load(session); }).subscribe();
    }
    void supabase.auth.getSession().then(({ data }) => load(data.session));
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => { void load(session); });
    return () => { live = false; listener.subscription.unsubscribe(); if (channel) void supabase.removeChannel(channel); };
  }, []);
  useEffect(() => {
    const root = document.documentElement;
    root.style.setProperty("--tenant-primary", brand.cor_primaria);
    root.style.setProperty("--tenant-secondary", brand.cor_secundaria);
    const theme = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
    if (theme) theme.content = brand.cor_primaria;
    document.title = brand.nome_fantasia ? `${brand.nome_fantasia} · PDV` : "PDV";
  }, [brand]);
  return <BrandContext.Provider value={{ brand, ready }}>{children}</BrandContext.Provider>;
}

export function useTenantBranding() { return useContext(BrandContext); }

export function TenantBrandMark({ compact = false }: { compact?: boolean }) {
  const { brand } = useTenantBranding();
  return <div className="flex items-center gap-3 min-w-0">
    {brand.logo_url ? <img src={brand.logo_url} alt={`Logo ${brand.nome_fantasia}`} className={`${compact ? "h-8 w-8" : "h-11 w-11"} rounded object-contain bg-white p-1`} /> : <span className={`${compact ? "h-8 w-8" : "h-11 w-11"} rounded grid place-items-center text-white font-bold`} style={{ backgroundColor: "var(--tenant-secondary)" }}>{(brand.nome_fantasia || "P").trim().slice(0, 1).toUpperCase()}</span>}
    <span className="truncate font-semibold">{brand.nome_fantasia || "PDV"}</span>
  </div>;
}
