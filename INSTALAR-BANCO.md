# PediHub — instalar o banco de dados

O PediHub tem um banco **só dele**, separado do AgendaPro. Ele começa com a
mesma estrutura do AgendaPro, testada, com o nome trocado para PediHub. Os
módulos que o restaurante não usa ficam guardados no banco, sem atrapalhar.
O app só para de mostrá-los depois.

São 4 passos no site do Supabase e 1 no código. Não precisa instalar nada no
computador.

---

## 1. Criar o projeto

1. Entre em **supabase.com** → **New project**.
2. Nome: `pedihub`. Região: **South America (São Paulo)**.
3. Crie uma **senha do banco** e **guarde num lugar seguro**. Ela é pedida no
   backup e em outras configurações.
4. Espere uns 2 minutos até o projeto ficar pronto.

## 2. Instalar o banco (duas colagens)

No painel do projeto, vá em **SQL Editor → New query**.

1. Abra o arquivo **`supabase/00_tudo_parte1.sql`**, copie **tudo**, cole no
   editor e clique em **Run**. Espere terminar.
2. Clique em **New query** de novo, faça o mesmo com
   **`supabase/00_tudo_parte2.sql`** e clique em **Run**.

> Se aparecer **"PAREI SEM GRAVAR NADA: os acentos..."**, o arquivo foi
> copiado com a codificação errada e nada foi gravado. Abra pelo GitHub, no
> botão **Raw**, copie de lá e cole de novo.
>
> Pode rodar as duas partes de novo quantas vezes quiser. Nada é apagado.

## 3. Conferir

**New query** → cole **`supabase/CONFERIR.sql`** → **Run**.

Devem sair **85 linhas, todas com `certo`** na coluna do meio. Se alguma disser
`FALTA` ou `ERRADO`, cole o **`supabase/98_modulos.sql`** inteiro, rode, e
confira de novo.

## 4. Criar a sua conta de dono da plataforma

1. **Authentication → Users → Add user → Create new user**. Use seu e-mail e
   uma senha, e marque **Auto Confirm User**.
2. **SQL Editor → New query** → cole **`tests/promover_admin.sql`**, troque
   `TROQUE-PELO-SEU@EMAIL.COM` pelo e-mail do passo anterior → **Run**.
   No fim aparece uma lista: ela deve ter só você.

## 5. Ligar o app no banco novo

Em **Settings → API Keys** (ou **Settings → API**, em projetos antigos), copie:

- **Project URL**, que tem o formato `https://xxxxxxxx.supabase.co`
- **Publishable key**, que começa com `sb_publishable_...`

**Já feito:** esses dois valores estão no `config.js`. Os dois podem
aparecer no site: não são segredo. Quem protege os dados são as regras dentro
do banco.

> ⚠ **NUNCA** me mande, e nunca coloque em arquivo nenhum, a **Secret key**
> (`sb_secret_...`) nem a `service_role`. Elas passam por cima de toda a
> proteção do banco.

Enquanto o `config.js` estiver vazio, o PediHub roda em **modo
demonstração**: os dados ficam no navegador e não tocam em banco nenhum.

---

## Depois, quando for ligar o WhatsApp (não precisa agora)

As mensagens de pedido (recebido, aceito, saiu para entrega, pronto,
cancelado) saem pelo WhatsApp oficial da Meta. Isso é uma etapa à parte, que
a gente faz junto:

- os **modelos de mensagem** agora se chamam `pedihub_...` e precisam ser
  aprovados na Meta (os textos estão em
  `supabase/functions/enviar-notificacoes/MODELOS.md`);
- as funções do Supabase são publicadas pelo GitHub, que já aponta para o
  projeto do PediHub (`iarmxniueeqntshhjxuw`). Falta guardar o segredo
  `SUPABASE_ACCESS_TOKEN` no repositório;
- o **`supabase/LIGAR-WHATSAPP.sql`** liga o envio automático. Nele você só
  troca a frase secreta, como está explicado no próprio arquivo.

Pagamento da assinatura (Mercado Pago) e backup automático também ficam para
essa etapa.

---

## O que mudou em relação ao AgendaPro

| | AgendaPro | PediHub |
|---|---|---|
| Projeto Supabase | o dele | **um novo, separado** |
| Endereço do banco no `config.js` | o dele | **o do PediHub** (`iarmxniueeqntshhjxuw`) |
| Nome em mensagens, modelos e travas internas | `agendapro` | `pedihub` |
| Domínio | agendaprogestao.com.br | nenhum por enquanto (`alelima30.github.io/pedihub`) |

O banco foi instalado do zero num Postgres de teste antes de chegar até você:
as duas partes rodaram sem erro, inclusive na segunda vez, o `CONFERIR.sql`
deu 85 de 85 `certo`, e todos os testes de banco passaram.
