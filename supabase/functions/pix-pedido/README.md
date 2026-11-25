# Ligar o Pix online (módulo 81)

O cliente paga o Pix na hora de pedir e o pedido chega na cozinha já **PAGO**.
O dinheiro cai na conta do **Mercado Pago do restaurante**, não passa pelo
PediHub. Cada restaurante conecta a conta dele com um botão no painel
(**Pedidos → Entrega e pagamento → Conectar Mercado Pago**).

Para isso funcionar, uma vez só, do lado do PediHub:

## 1. O aplicativo PediHub no Mercado Pago

Em https://www.mercadopago.com.br/developers/panel/app, com a conta do
Mercado Pago **do PediHub**:

1. **Criar aplicação** → nome `PediHub` → **Pagamentos online** →
   plataforma de e-commerce: **Não** → **Checkout Transparente**.
2. Nas configurações da aplicação, em **URLs de redirecionamento**:
   ```
   https://iarmxniueeqntshhjxuw.supabase.co/functions/v1/mp-conectar
   ```
3. Em **Credenciais de produção**: o **Client ID** e o **Client Secret**.

## 2. Os segredos no Supabase

**Edge Functions → Secrets → Add new secret**:

| nome | valor |
|---|---|
| `MP_CLIENT_ID` | o Client ID do aplicativo (não é segredo, mas mora aqui) |
| `MP_CLIENT_SECRET` | o Client Secret do aplicativo |
| `MP_PAGADOR_EMAIL` | um e-mail do PediHub (o Mercado Pago exige um "pagador" no Pix; o cliente não precisa dar o dele) |

> ⚠ Nenhum desses valores vai no `config.js`, no código ou numa conversa.

## 3. Publicar

As funções `mp-conectar` e `pix-pedido` publicam sozinhas pelo GitHub
(`publicar-funcoes.yml`) quando mudam. Para publicar na hora:
**GitHub → Actions → Publicar as funções → Run workflow**.

## O que o restaurante precisa

- Uma conta no Mercado Pago (CPF ou CNPJ) **com uma chave Pix cadastrada**
  — sem chave Pix, o Mercado Pago não gera o QR.
- Tocar em **Conectar Mercado Pago**, entrar na conta dele e **Autorizar**.
  O Pix online já aparece no link; dá para desligar na mesma janela.

## Como funciona por dentro

- O pedido nasce `aguardando_pagamento`: fora da tela de Pedidos, sem aviso
  no celular e sem WhatsApp para o restaurante.
- O cliente vê o QR e o copia-e-cola; a tela pergunta a cada 5 s se caiu.
- Quando o Pix cai, o Mercado Pago avisa o `pix-pedido?aviso=<pedido>`. O
  aviso **não é acreditado**: a função busca o pagamento no Mercado Pago com
  a credencial do restaurante e só confirma se está aprovado, é deste pedido
  e tem o valor certo (`pix_confirmar`, que confere de novo no banco).
- 30 minutos sem pagar: o pedido é cancelado ("o Pix não foi pago").
- A credencial do restaurante dura 180 dias e é renovada sozinha.
- Para devolver um Pix de um pedido cancelado: pelo app do Mercado Pago do
  restaurante (Atividade → o pagamento → Devolver).
