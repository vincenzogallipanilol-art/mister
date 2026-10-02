import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
// @deno-types="npm:@types/web-push"
import webpush from 'npm:web-push'

const VAPID_PUBLIC = Deno.env.get('VAPID_PUBLIC_KEY')!
const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY')!
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

webpush.setVapidDetails('mailto:admin@mister.app', VAPID_PUBLIC, VAPID_PRIVATE)

serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 })

  let body: { title?: string; body?: string; url?: string } = {}
  try { body = await req.json() } catch (_) { return new Response('Bad JSON', { status: 400 }) }

  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)
  const { data: subs, error } = await sb.from('push_subs').select('sub')
  if (error) return new Response(error.message, { status: 500 })

  const payload = JSON.stringify({ title: body.title || 'MISTER', body: body.body || '', url: body.url || './' })
  const results = await Promise.allSettled(
    (subs || []).map(row => webpush.sendNotification(row.sub, payload).catch(async (e: { statusCode?: number }) => {
      // Remove expired/invalid subscriptions
      if (e.statusCode === 404 || e.statusCode === 410) {
        await sb.from('push_subs').delete().eq('endpoint', row.sub.endpoint)
      }
      throw e
    }))
  )
  const sent = results.filter(r => r.status === 'fulfilled').length
  return new Response(JSON.stringify({ sent, total: subs?.length ?? 0 }), {
    headers: { 'Content-Type': 'application/json' }
  })
})
