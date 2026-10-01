/* Adattatore: espone a MISTER la stessa interfaccia "window.claude" (db, user) sopra Supabase */
(()=>{
const C=window.MISTER_CFG||{};
const sb=window.supabase.createClient(C.url,C.anon,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
let ME=null; // {id,role,name}
const $=s=>document.querySelector(s);
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const CSS=`#auth{position:fixed;inset:0;z-index:99999;background:#0e0e10;color:#f2f4f7;display:flex;align-items:center;justify-content:center;padding:20px;font-family:system-ui,sans-serif}
#auth .box{width:100%;max-width:360px}#auth h1{letter-spacing:.2em;margin:0 0 4px;font-size:28px}#auth h1 b{color:#d1ff42}
#auth p{color:#9096a0;font-size:14px;margin:0 0 18px}#auth input{width:100%;box-sizing:border-box;background:#18181b;border:1px solid #2b2b30;color:#f2f4f7;border-radius:12px;padding:13px;font-size:16px;margin-bottom:10px}
#auth button{width:100%;border:0;border-radius:12px;padding:13px;font-size:16px;font-weight:700;background:#d1ff42;color:#12160a;margin-bottom:10px;cursor:pointer}
#auth button.sec{background:#232327;color:#f2f4f7;font-weight:600}#auth .err{color:#ff7b7b;font-size:13px;min-height:18px;margin-bottom:8px}`;
const st=document.createElement('style');st.textContent=CSS;document.head.appendChild(st);
function overlay(html){let a=$('#auth');if(!a){a=document.createElement('div');a.id='auth';document.body.appendChild(a)}a.innerHTML=`<div class="box"><h1>MIS<b>TER</b></h1>${html}</div>`;return a}
const closeOv=()=>{const a=$('#auth');if(a)a.remove()};

function loginUI(){return new Promise(res=>{
 let mode='in';
 const draw=(err='')=>{overlay(`<p>${mode==='in'?'Accedi per continuare':'Crea il tuo account'}</p><div class="err">${esc(err)}</div>
  <input id="au_e" type="email" placeholder="Email" autocomplete="email"><input id="au_p" type="password" placeholder="Password (min. 6)" autocomplete="${mode==='in'?'current-password':'new-password'}">
  <button id="au_go">${mode==='in'?'Accedi':'Registrati'}</button>
  ${C.google?'<button class="sec" id="au_g">Continua con Google</button>':''}
  <button class="sec" id="au_m">${mode==='in'?'Non hai un account? Registrati':'Hai già un account? Accedi'}</button>`);
  $('#au_m').onclick=()=>{mode=mode==='in'?'up':'in';draw()};
  if($('#au_g'))$('#au_g').onclick=()=>sb.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin+location.pathname}});
  $('#au_go').onclick=async()=>{const email=$('#au_e').value.trim(),password=$('#au_p').value;
   if(!email||password.length<6)return draw('Email e password (min. 6 caratteri)');
   const r=mode==='in'?await sb.auth.signInWithPassword({email,password}):await sb.auth.signUp({email,password});
   if(r.error)return draw(r.error.message);
   if(!r.data.session)return draw('Conferma l\'email dal messaggio ricevuto, poi accedi.');
   res(r.data.session)}};
 draw()})}

function inviteUI(){return new Promise(res=>{
 const pre=new URLSearchParams(location.search).get('invite')||'';
 const draw=(err='')=>{overlay(`<p>Serve un codice d'invito dell'amministratore.</p><div class="err">${esc(err)}</div>
  <input id="iv_n" placeholder="Il tuo nome" autocomplete="name"><input id="iv_c" placeholder="Codice invito" value="${esc(pre)}" autocapitalize="off">
  <button id="iv_go">Entra</button><button class="sec" id="iv_out">Esci</button>`);
  $('#iv_out').onclick=async()=>{await sb.auth.signOut();location.reload()};
  $('#iv_go').onclick=async()=>{const code=$('#iv_c').value.trim();if(!code)return draw('Inserisci il codice');
   const {data,error}=await sb.rpc('redeem_invite',{p_code:code,p_name:$('#iv_n').value.trim()||null});
   if(error)return draw(error.message.includes('invito')?'Invito non valido o scaduto':error.message);
   res(data)}};
 draw()})}

let authP=null;
function ensureAuth(){return authP||(authP=(async()=>{
 let {data:{session}}=await sb.auth.getSession();
 if(!session)session=await loginUI();
 let {data:prof}=await sb.from('profiles').select('id,role,name').eq('id',session.user.id).maybeSingle();
 if(!prof){await inviteUI();({data:prof}=await sb.from('profiles').select('id,role,name').eq('id',session.user.id).maybeSingle())}
 ME={id:session.user.id,role:prof?prof.role:'player',name:prof&&prof.name};
 closeOv();window.MISTER_ME=ME;return ME})())}

/* ---- db ---- */
const listeners=new Set();let chan=null,tm=null;
function startRT(){if(chan)return;chan=sb.channel('docs').on('postgres_changes',{event:'*',schema:'public',table:'docs'},()=>{clearTimeout(tm);tm=setTimeout(()=>listeners.forEach(f=>f()),120)}).subscribe();
 document.addEventListener('visibilitychange',()=>{if(!document.hidden)listeners.forEach(f=>f())})}
const errOf=e=>{const x=new Error(e.message);x.code=(e.code==='42501'||/row-level/i.test(e.message||''))?'invalid_argument':e.code;return x};
const snapDoc=(path,row)=>({id:path.split('/').pop(),exists:!!row,data:()=>row?row.data:undefined});
const rowDoc=r=>({id:r.id,exists:true,data:()=>r.data});
const db={
 doc:path=>({
  async set(d){const [col,...rest]=path.split('/');const {error}=await sb.from('docs').upsert({path,col,id:rest.join('/'),data:d});if(error)throw errOf(error)},
  async delete(){const {error}=await sb.from('docs').delete().eq('path',path);if(error)throw errOf(error)},
  async get(){const {data,error}=await sb.from('docs').select('data').eq('path',path).maybeSingle();if(error)throw errOf(error);return snapDoc(path,data)},
  onSnapshot(cb,err){const f=()=>this.get().then(cb).catch(err||(()=>{}));listeners.add(f);startRT();f();return()=>listeners.delete(f)}}),
 collection:col=>({
  async get(){const {data,error}=await sb.from('docs').select('id,data').eq('col',col);if(error)throw errOf(error);const docs=(data||[]).map(rowDoc);return{docs,size:docs.length}},
  onSnapshot(cb,err){const f=()=>this.get().then(cb).catch(err||(()=>{}));listeners.add(f);startRT();f();return()=>listeners.delete(f)}})
};

window.claude={use:async n=>{
 if(n==='db'){await ensureAuth();return db}
 if(n==='user'){const m=await ensureAuth();return{id:async()=>m.id,canEdit:()=>m.role==='admin',isOwner:()=>false}}
 return null}};
window.MisterSB=sb;

/* ---- push ---- */
const b64=s=>{const p='='.repeat((4-s.length%4)%4),r=atob((s+p).replace(/-/g,'+').replace(/_/g,'/'));return Uint8Array.from([...r].map(c=>c.charCodeAt(0)))};
window.MisterPush={
 supported:()=>'serviceWorker' in navigator&&'PushManager' in window&&'Notification' in window,
 state:()=>!('Notification' in window)?'unsupported':Notification.permission,
 async enable(){
  if(!this.supported())throw new Error('Notifiche non supportate: su iPhone aggiungi prima l\'app alla schermata Home');
  const perm=await Notification.requestPermission();if(perm!=='granted')throw new Error('Permesso negato');
  const reg=await navigator.serviceWorker.ready;
  const sub=await reg.pushManager.getSubscription()||await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:b64(C.vapid)});
  const {error}=await sb.from('push_subs').upsert({endpoint:sub.endpoint,user_id:ME.id,sub:sub.toJSON()});
  if(error)throw error;return true},
 async notify(title,body,url){const {data,error}=await sb.functions.invoke('notify',{body:{title,body,url}});if(error)throw error;return data}
};
if('serviceWorker' in navigator)navigator.serviceWorker.register('sw.js').catch(()=>{});
})();
