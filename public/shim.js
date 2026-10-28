/* Adattatore Supabase per MISTER – auth Google OAuth (unica via, admin incluso) */
(()=>{
const C=window.MISTER_CFG||{};
const sb=window.supabase.createClient(C.url,C.anon,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
let ME=null;

const $=s=>document.querySelector(s);
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

/* ---- UI overlay ---- */
const CSS=`#auth{position:fixed;inset:0;z-index:99999;background:#0e0e10;color:#f2f4f7;display:flex;align-items:center;justify-content:center;padding:20px;font-family:system-ui,sans-serif}
#auth .box{width:100%;max-width:340px;text-align:center}
#auth h1{letter-spacing:.25em;margin:0 0 4px;font-size:32px;font-weight:900}#auth h1 b{color:#d1ff42}
#auth p{color:#9096a0;font-size:14px;margin:0 0 24px;line-height:1.5}
#auth button{width:100%;border:0;border-radius:14px;padding:14px;font-size:16px;font-weight:800;background:#d1ff42;color:#12160a;cursor:pointer;letter-spacing:.04em}
#auth .err{color:#ff7b7b;font-size:13px;min-height:18px;margin-bottom:10px}
#auth .gbtn{background:#fff;color:#3c4043;border:1px solid #dadce0;display:flex;align-items:center;justify-content:center;gap:10px;font-weight:600;font-size:15px}
#auth .gbtn:active{background:#f1f3f4}
#auth .pen{font-size:46px;margin-bottom:10px}
#auth .mail{color:#d1ff42;font-size:13px;margin:-14px 0 24px}
#auth .sec{background:#18181b;color:#f2f4f7;border:1px solid #2b2b30;margin-top:8px}`;
const st=document.createElement('style');st.textContent=CSS;document.head.appendChild(st);

function overlay(html){let a=$('#auth');if(!a){a=document.createElement('div');a.id='auth';document.body.appendChild(a)}a.innerHTML=`<div class="box">${html}</div>`;return a}
const closeOv=()=>{const a=$('#auth');if(a)a.remove()};

const GICON=`<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#4285F4" d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844a4.14 4.14 0 0 1-1.796 2.716v2.259h2.908c1.702-1.567 2.684-3.875 2.684-6.615z"/><path fill="#34A853" d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 0 0 9 18z"/><path fill="#FBBC05" d="M3.964 10.71A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 0 0 0 9c0 1.452.348 2.827.957 4.042l3.007-2.332z"/><path fill="#EA4335" d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.958L3.964 6.29C4.672 4.163 6.656 3.58 9 3.58z"/></svg>`;

async function signInWithGoogle(){
 const clean=window.location.origin+window.location.pathname;
 await sb.auth.signInWithOAuth({provider:'google',options:{redirectTo:clean}});
}

/* ---- Login screen: solo Google ---- */
function loginUI(err=''){return new Promise(()=>{ // non risolve: il click reindirizza la pagina
 overlay(`
  <h1>MIS<b>TER</b></h1>
  <p>Accedi con il tuo account Google<br>per entrare nell'app</p>
  <div class="err">${esc(err)}</div>
  <button id="tk_g" class="gbtn">${GICON} Accedi con Google</button>`);
 $('#tk_g').onclick=async()=>{$('#tk_g').textContent='...';await signInWithGoogle()}})}

/* ---- Schermata "in attesa di approvazione" (blocca l'app) ---- */
function pendingUI(email,name){return new Promise(()=>{
 overlay(`<div class="pen">⏳</div>
  <h1 style="font-size:22px">In attesa</h1>
  <p>Ciao${name?' '+esc(name):''}! Il tuo accesso Google è stato registrato.<br>L'amministratore ti collegherà al tuo profilo giocatore a breve.</p>
  <div class="mail">${esc(email)}</div>
  <button id="pen_refresh">Controlla di nuovo</button>
  <button id="pen_out" class="sec">Esci</button>`);
 $('#pen_refresh').onclick=()=>location.reload();
 $('#pen_out').onclick=async()=>{await sb.auth.signOut();location.reload()}})}

function linkDoc(id,pid){
 sb.from('docs').select('id').eq('path','links/'+id).maybeSingle().then(({data})=>{
  if(!data)sb.from('docs').upsert({path:'links/'+id,col:'links',id,data:{id,p:pid}});
 });
}

/* avvisa SOLO gli admin (via push) quando un nuovo account Google chiede accesso */
async function notifyAdminsNewAccess(email,name){
 try{
  const {data:admins}=await sb.rpc('admin_push_targets');
  const ids=(admins||[]).map(r=>r.auth_uid).filter(Boolean);
  if(!ids.length)return;
  await sb.functions.invoke('notify',{body:{
   title:'👤 Nuovo accesso Google',
   body:(name||email||'Un utente')+' ha richiesto l\'accesso a MISTER — collegalo a un giocatore',
   url:'./?admin=google',
   type:'new_google_user',
   users:ids
  }});
 }catch(e){/* best-effort */}
}

function clearAuthHash(){
 if(/access_token=|refresh_token=|[?&]code=/.test(window.location.hash+window.location.search)){
  history.replaceState(null,'',window.location.pathname+window.location.search.replace(/[?&]?code=[^&]*/,'')||window.location.pathname);
 }
}

let authP=null;
function ensureAuth(){return authP||(authP=(async()=>{
 const {data:{session}}=await sb.auth.getSession();

 if(!session){
  // sb.auth.getSession() può risolvere prima che l'SDK consumi il codice
  // OAuth presente nell'URL di ritorno: ridà un'occhiata una volta sola.
  if(/[?&]code=|access_token=/.test(window.location.href)){
   await new Promise(r=>setTimeout(r,400));
   const retry=await sb.auth.getSession();
   if(retry.data.session)return handleSession(retry.data.session);
  }
  return loginUI();
 }
 return handleSession(session);

 async function handleSession(session){
  clearAuthHash();
  const {data,error}=await sb.rpc('register_google_user',{
   p_email:session.user.email||'',
   p_display_name:session.user.user_metadata?.full_name||session.user.user_metadata?.name||''
  });
  if(error){
   await sb.auth.signOut().catch(()=>{});
   return loginUI('Errore di accesso: '+error.message);
  }
  if(data.is_new&&data.status==='pending')notifyAdminsNewAccess(session.user.email||'',session.user.user_metadata?.full_name||session.user.user_metadata?.name||'');
  if(data.status==='linked'){
   ME={id:session.user.id,type:'google',uid:session.user.id,role:data.role||'player',pid:data.pid||null,name:data.name,email:session.user.email};
   window.MISTER_ME=ME;
   if(ME.pid)linkDoc(session.user.id,ME.pid);
   return ME;
  }
  // pending o new: blocca l'app finché l'admin non collega l'utente
  return pendingUI(session.user.email||'',session.user.user_metadata?.full_name||session.user.user_metadata?.name||'');
 }
})())}

/* ---- DB ---- */
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

/* ---- Admin: utenti Google in attesa ---- */
window.MisterGoogleAdmin={
 async listPending(){
  if(!ME||ME.role!=='admin')throw new Error('non autorizzato');
  const {data,error}=await sb.rpc('list_pending_google_users');
  if(error)throw new Error(error.message);
  return data||[];
 },
 /* pid già collegati ad un account Google (su un altro, già censito): da escludere
    dalla scelta quando si collega un nuovo account, per non doppiare un giocatore */
 async linkedPids(){
  if(!ME||ME.role!=='admin')throw new Error('non autorizzato');
  const {data,error}=await sb.rpc('linked_player_ids');
  if(error)throw new Error(error.message);
  return (data||[]).map(r=>r.pid).filter(Boolean);
 },
 async link(authUid,pid){
  if(!ME||ME.role!=='admin')throw new Error('non autorizzato');
  const {data,error}=await sb.rpc('link_google_user',{p_auth_uid:authUid,p_pid:pid});
  if(error)throw new Error(error.message);
  return data;
 },
 async unlink(authUid){
  if(!ME||ME.role!=='admin')throw new Error('non autorizzato');
  const {data,error}=await sb.rpc('unlink_google_user',{p_auth_uid:authUid});
  if(error)throw new Error(error.message);
  return data;
 }
};

/* ---- Auth esposta all'app ---- */
window.MisterAuth={
 async signOut(){
  try{await sb.auth.signOut()}catch(e){}
  location.reload();
 },
 signInWithGoogle,
 me(){return ME}
};

window.claude={use:async n=>{
 if(n==='db'){await ensureAuth();return db}
 if(n==='user'){const m=await ensureAuth();return{id:async()=>m.id,canEdit:()=>m.role==='admin',isOwner:()=>false}}
 return null}};
window.MisterSB=sb;

/* ---- Push ---- */
const b64=s=>{const p='='.repeat((4-s.length%4)%4),r=atob((s+p).replace(/-/g,'+').replace(/_/g,'/'));return Uint8Array.from([...r].map(c=>c.charCodeAt(0)))};
window.MisterPush={
 supported:()=>'serviceWorker' in navigator&&'PushManager' in window&&'Notification' in window,
 state:()=>!('Notification' in window)?'unsupported':Notification.permission,
 async enable(){
  if(!this.supported())throw new Error('Notifiche non supportate: su iPhone aggiungi prima l\'app alla schermata Home');
  const perm=await Notification.requestPermission();if(perm!=='granted')throw new Error('Permesso negato');
  const reg=await navigator.serviceWorker.ready;
  const sub=await reg.pushManager.getSubscription()||await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:b64(C.vapid)});
  const {error}=await sb.from('push_subs').upsert({endpoint:sub.endpoint,user_id:(ME&&(ME.pid||ME.uid||ME.id)),pid:ME&&ME.pid,sub:sub.toJSON()});
  if(error)throw error;return true},
 async endpoint(){if(!this.supported())return null;const reg=await navigator.serviceWorker.ready;const sub=await reg.pushManager.getSubscription();return sub?sub.endpoint:null},
 async getPrefs(){const ep=await this.endpoint();if(!ep)return{};const {data,error}=await sb.from('push_subs').select('prefs').eq('endpoint',ep).maybeSingle();if(error)throw error;return(data&&data.prefs)||{}},
 async setPrefs(prefs){const ep=await this.endpoint();if(!ep)throw new Error('Attiva prima le notifiche');const {error}=await sb.from('push_subs').update({prefs}).eq('endpoint',ep);if(error)throw error;return true},
 async notify(title,body,url,type,users){
  const {data:kill}=await sb.from('docs').select('data').eq('path','settings/notify_kill').maybeSingle();
  if(kill&&kill.data&&kill.data.off)return{sent:0,skipped:'kill_switch'};
  const {data,error}=await sb.functions.invoke('notify',{body:{title,body,url,type:type||null,users:users||null}});if(error)throw error;return data}
};
if('serviceWorker' in navigator)navigator.serviceWorker.register('sw.js').catch(()=>{});
})();
