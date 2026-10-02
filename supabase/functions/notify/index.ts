import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

webpush.setVapidDetails(
  'mailto:vincenzogallipanilol@gmail.com',
  Deno.env.get('VAPID_PUBLIC_KEY')!,
  Deno.env.get('VAPID_PRIVATE_KEY')!,
)

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: cors })

  let body: { title?: string; body?: string; url?: string; type?: string | null } = {}
  try { body = await req.json() } catch (_) { /* body vuoto */ }

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: subs, error } = await sb.from('push_subs').select('endpoint, sub, prefs')
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } })

  // Filtra per tipo: invia se la preferenza non è esplicitamente false
  const type = body.type || null
  const targets = (subs || []).filter((r) => !type || (r.prefs || {})[type] !== false)

  const payload = JSON.stringify({ title: body.title || 'MISTER', body: body.body || '', url: body.url || './' })
  let sent = 0
  await Promise.all(targets.map(async (r) => {
    try {
      await webpush.sendNotification(r.sub, payload)
      sent++
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode
      if (code === 404 || code === 410) await sb.from('push_subs').delete().eq('endpoint', r.endpoint)
    }
  }))

  return new Response(JSON.stringify({ sent, total: targets.length }), {
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
})
