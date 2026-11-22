import { createClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
if (!url || !key) throw new Error("Configure NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_ANON_KEY.");
export const supabase = createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });

export type Variation = { id: string; produto_id: string; sku: string; codigo_barras: string | null; cor: string; tamanho: string; preco: number; estoque: number };
export type CartItem = { id: string; variacao_id: string; quantidade: number; variacao: Variation & { produto: { nome: string } } };
