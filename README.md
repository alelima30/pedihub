# PediHub

Cardápio digital com pedidos para **restaurante, lanchonete, pizzaria e
delivery** — sem comissão por pedido. HTML/CSS/JS puro, sem build, backend
Supabase, app instalável (PWA).

Nasceu de uma cópia do AgendaPro (agenda de salão) e virou só pedidos: a
agenda, os serviços, os pacotes e a comissão saíram das telas; o banco
trava toda casa como restaurante (`64_so_restaurante.sql`).

- **Site:** https://alelima30.github.io/pedihub/
- **Página de venda:** `conheca.html`
- **Instalar o banco:** [`INSTALAR-BANCO.md`](INSTALAR-BANCO.md)

---

## O que tem

| Para quem | O quê |
|---|---|
| **Cliente** (`cardapio.html?salao=…`) | Cardápio por categoria, complementos e variações (tamanho, meio a meio, borda, adicionais), carrinho, entrega com taxa por bairro ou retirada, troco, cupom, acompanhamento do pedido e fidelidade. Pelo QR da mesa (`&mesa=N`): pedido na mesa, sem endereço, pagando no fim. |
| **Restaurante** (`app.html`) | Pedidos em colunas com som, aviso no celular e impressão (automática por aparelho); pedido por telefone e balcão; cardápio com complementos e "esgotado" com um toque; entrega e pagamento, mesas com QR, entregadores e o acerto, fidelidade; cupons; caixa, dashboard e relatórios; clientes, aniversariantes e equipe. |
| **Plataforma** (`admin.html`) | Os restaurantes, as assinaturas e o check-up do sistema. |

**Planos** (`66_planos_pedihub.sql`): Grátis (até 50 pedidos/mês), Essencial
R$ 69,90 e Profissional R$ 119,90 (com WhatsApp automático e crediário). O
preço muda com o `supabase/PRECOS.sql`.

## Os arquivos

| Arquivo | O que faz |
|---|---|
| `app.html` | O painel do restaurante |
| `cardapio.html` | O cardápio e o pedido do cliente (`agendar.html` só redireciona, para links antigos) |
| `criar.html`, `entrar.html`, `nova-senha.html`, `convite.html` | Cadastro, login, senha e convite da equipe |
| `conheca.html` | A página de venda |
| `config.js` | **O único arquivo a editar** para ligar no Supabase |
| `dados.js` | A camada de dados: demonstração (navegador) ou Supabase |
| `demo.js` | A demonstração: Pizzaria Bella Massa e Hamburgueria do Zé (`?demo=1`) |
| `estilo.css` | Cores (laranja-brasa e carvão), tipografia e componentes |
| `supabase/00_tudo_parte1.sql` e `_parte2.sql` | A instalação do banco, em duas colagens |
| `supabase/98_modulos.sql` | A atualização de um banco já instalado |
| `supabase/CONFERIR.sql` | A conferência: tudo tem de dar "certo" |

### Os módulos do PediHub no banco

| Módulo | O quê |
|---|---|
| `64_so_restaurante.sql` | Toda casa é restaurante |
| `65_pedido_vira_venda.sql` | O pedido entregue entra no caixa, nos relatórios e no estoque |
| `66_planos_pedihub.sql` | Os planos e o limite do Grátis |
| `67_complementos.sql` | Complementos e variações do cardápio |
| `68_cupom_no_pedido.sql` | O cupom no pedido, sobre o subtotal |
| `69_esgotado.sql` | "Esgotado" com um toque, por qualquer um da equipe |
| `70_pedido_balcao.sql` | O núcleo do pedido e o pedido lançado pela equipe |
| `71_mesas_entregadores_fidelidade.sql` | Mesas com QR, entregadores e o acerto, fidelidade |

A regra da casa: **o preço é do banco**. A página manda só o que e quantos;
preço, complementos, cupom, taxa e total são calculados e conferidos no
Supabase.

## Testar

Sem instalar nada: abra `app.html?demo=1`. Os testes automáticos estão no
[`COMO-TESTAR.md`](COMO-TESTAR.md) (`bash tests/rodar.sh` para o banco,
`bash tests/tudo.sh` para tudo).
