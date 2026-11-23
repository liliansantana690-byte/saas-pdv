"use client";
export type Receipt = { loja: { nome_fantasia: string; cnpj: string; endereco: string; telefone: string; logo_url?: string | null }; venda: { id: string; created_at: string; total: number; forma_pagamento: string; operador: string; cliente_nome?: string | null; cliente_cpf?: string | null; itens: { nome: string; cor: string; tamanho: string; quantidade: number; preco_unitario: number }[] } };
const money = (n: number) => n.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const cpfMasked = (cpf?: string | null) => cpf ? `***.***.${cpf.slice(6, 9)}-${cpf.slice(-2)}` : "";
export default function ReciboTermico({ data, width = 80 }: { data: Receipt; width?: 58 | 80 }) {
  return <article className="receipt" data-width={width}>
    <center>{data.loja.logo_url&&<img src={data.loja.logo_url} alt="" style={{maxWidth:"42mm",maxHeight:"18mm",objectFit:"contain"}}/>}<br/><strong>{data.loja.nome_fantasia}</strong><br/>CNPJ {data.loja.cnpj}<br/>{data.loja.endereco}<br/>{data.loja.telefone}</center><hr/>
    <div>Pedido: {data.venda.id.slice(0, 8).toUpperCase()}<br/>Data: {new Date(data.venda.created_at).toLocaleString("pt-BR")}<br/>Operador: {data.venda.operador}</div><hr/>
    {data.venda.cliente_nome && <div>Cliente: {data.venda.cliente_nome}<br/>CPF: {cpfMasked(data.venda.cliente_cpf)}</div>}
    <table style={{ width: "100%", borderCollapse: "collapse" }}><tbody>{data.venda.itens.map((i, n) => <tr key={`${i.nome}-${n}`}><td colSpan={2}>{i.nome} {i.cor}/{i.tamanho}<br/>{i.quantidade} x {money(i.preco_unitario)}</td><td style={{ textAlign: "right", verticalAlign: "top" }}>{money(i.quantidade * i.preco_unitario)}</td></tr>)}</tbody></table>
    <hr/><strong style={{ display: "flex", justifyContent: "space-between" }}><span>TOTAL</span><span>{money(data.venda.total)}</span></strong><div>Pagamento: {data.venda.forma_pagamento}</div><hr/><center><strong>DOCUMENTO SEM VALOR FISCAL</strong><br/>Obrigado pela preferência!</center>
  </article>;
}
