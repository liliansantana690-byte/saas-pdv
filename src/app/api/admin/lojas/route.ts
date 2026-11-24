import { createClient } from "@supabase/supabase-js";
import { randomBytes } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";

export const runtime = "nodejs";

type ProvisionInput = {
  nomeFantasia?: unknown;
  cnpj?: unknown;
  endereco?: unknown;
  telefone?: unknown;
  pdvCodigo?: unknown;
  pdvNome?: unknown;
  gerenteNome?: unknown;
  gerenteCpf?: unknown;
  gerenteChapa?: unknown;
  gerentePin?: unknown;
};

function text(value: unknown, max = 160) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

function serverConfig() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const secretKey = process.env.SUPABASE_SECRET_KEY;
  const admins = (process.env.PLATFORM_ADMIN_EMAILS || "")
    .split(",")
    .map((email) => email.trim().toLowerCase())
    .filter(Boolean);

  if (!url || !anonKey || !secretKey || admins.length === 0) return null;
  return { url, anonKey, secretKey, admins };
}

async function authorize(request: NextRequest) {
  const config = serverConfig();
  if (!config) return { response: NextResponse.json({ error: "Configure o acesso administrativo na hospedagem." }, { status: 503 }) };

  const bearer = request.headers.get("authorization") || "";
  const token = bearer.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return { response: NextResponse.json({ error: "Entre com a conta administrativa." }, { status: 401 }) };

  const authClient = createClient(config.url, config.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await authClient.auth.getUser(token);
  if (error || !data.user?.email || !config.admins.includes(data.user.email.toLowerCase())) {
    return { response: NextResponse.json({ error: "Acesso restrito à administração da plataforma." }, { status: 403 }) };
  }

  const adminClient = createClient(config.url, config.secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return { config, adminClient };
}

export async function GET(request: NextRequest) {
  const access = await authorize(request);
  if ("response" in access) return access.response;

  const { data, error } = await access.adminClient
    .from("lojas")
    .select("id,codigo_acesso,nome_fantasia,cnpj,created_at")
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) return NextResponse.json({ error: "Não foi possível carregar as lojas." }, { status: 500 });
  return NextResponse.json({ lojas: data || [] });
}

export async function POST(request: NextRequest) {
  const access = await authorize(request);
  if ("response" in access) return access.response;

  let body: ProvisionInput;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Envie os dados do cadastro em formato válido." }, { status: 400 });
  }

  const nomeFantasia = text(body.nomeFantasia, 120);
  const cnpj = text(body.cnpj, 32).replace(/\D/g, "");
  const endereco = text(body.endereco, 240);
  const telefone = text(body.telefone, 40);
  const pdvCodigo = text(body.pdvCodigo, 20);
  const pdvNome = text(body.pdvNome, 80);
  const gerenteNome = text(body.gerenteNome, 120);
  const gerenteCpf = text(body.gerenteCpf, 20).replace(/\D/g, "");
  const gerenteChapa = text(body.gerenteChapa, 20);
  const gerentePin = text(body.gerentePin, 6);

  if (!nomeFantasia || !/^\d{14}$/.test(cnpj) || !pdvCodigo || !pdvNome || !gerenteNome || !/^\d{11}$/.test(gerenteCpf) || !/^[A-Za-z0-9-]{1,20}$/.test(gerenteChapa) || !/^\d{6}$/.test(gerentePin)) {
    return NextResponse.json({ error: "Confira os campos obrigatórios, o CNPJ, o CPF, a chapa e o PIN de 6 dígitos." }, { status: 400 });
  }

  // A senha do Supabase Auth é aleatória e nunca é o PIN. O PIN só é usado no banco, em hash.
  const senhaAuth = randomBytes(32).toString("base64url");
  const storeId = crypto.randomUUID();
  const operatorId = crypto.randomUUID();
  const authEmail = `pdv-${operatorId}@login.invalid`;

  const { data: created, error: authError } = await access.adminClient.auth.admin.createUser({
    email: authEmail,
    password: senhaAuth,
    email_confirm: true,
    user_metadata: { loja_id: storeId, operador_id: operatorId, tipo: "gerente_loja" },
  });

  if (authError || !created.user) {
    return NextResponse.json({ error: "Não foi possível criar o acesso do gerente no Supabase Auth." }, { status: 400 });
  }

  const { data, error } = await access.adminClient.rpc("admin_provisionar_loja", {
    p_loja_id: storeId,
    p_operador_id: operatorId,
    p_nome_fantasia: nomeFantasia,
    p_cnpj: cnpj,
    p_endereco: endereco,
    p_telefone: telefone,
    p_pdv_codigo: pdvCodigo,
    p_pdv_nome: pdvNome,
    p_gerente_nome: gerenteNome,
    p_gerente_cpf: gerenteCpf,
    p_gerente_chapa: gerenteChapa,
    p_gerente_auth_email: authEmail,
    p_gerente_pin: gerentePin,
    p_gerente_senha_auth: senhaAuth,
    p_auth_user_id: created.user.id,
  });

  if (error) {
    await access.adminClient.auth.admin.deleteUser(created.user.id);
    const duplicate = /duplicate key|unique constraint/i.test(error.message);
    return NextResponse.json({
      error: duplicate
        ? "CNPJ ou chapa já cadastrado. Confira os dados e tente novamente."
        : "Não foi possível salvar o cadastro. Confirme se a migração schema-v7.sql foi aplicada no Supabase.",
    }, { status: duplicate ? 409 : 500 });
  }

  return NextResponse.json({ loja: data, gerente: { nome: gerenteNome, chapa: gerenteChapa }, pdv: { codigo: pdvCodigo, nome: pdvNome } }, { status: 201 });
}
