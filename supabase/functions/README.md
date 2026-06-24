# Edge Functions — Mercado Pago (assinatura recorrente)

Duas funções sustentam a cobrança recorrente do Vida Rica:

| Função                   | JWT | O que faz                                                            |
| ------------------------ | --- | ------------------------------------------------------------------- |
| `mp-create-subscription` | sim | Cria a preapproval (assinatura mensal) e devolve o `init_point`.    |
| `mp-webhook`             | não | Recebe notificações do Mercado Pago e sincroniza `subscriptions`.   |

## 1. Secrets

```bash
supabase secrets set MP_ACCESS_TOKEN="APP_USR-xxxxxxxx"   # Access Token do Mercado Pago
supabase secrets set APP_RETURN_URL="https://SEU-APP/"    # opcional: volta após o checkout
```

`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` já são injetados automaticamente.

## 2. Deploy

```bash
supabase functions deploy mp-create-subscription
supabase functions deploy mp-webhook --no-verify-jwt
```

## 3. Webhook no Mercado Pago

No painel do Mercado Pago → **Suas integrações → Webhooks**, cadastre a URL:

```
https://<project-ref>.functions.supabase.co/mp-webhook
```

e assine o evento **Assinaturas (preapproval)**.

## Teste em sandbox

Use as credenciais de teste do Mercado Pago em `MP_ACCESS_TOKEN`. O
`init_point`/`sandbox_init_point` retornado abre o checkout de teste; ao
autorizar, o webhook marca a assinatura como `active` e libera o app.
