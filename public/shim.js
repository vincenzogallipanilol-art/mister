/* Adattatore Supabase per MISTER – auth tramite token nominativo */
(()=>{
const C=window.MISTER_CFG||{};
const sb=window.supabase.createClient(C.url,C.anon,{auth:{persistSession:false}});
const AUTH_KEY='mister_session';
let ME=null;

const $=s=>document.querySelector(s);
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

/* ---- UI overlay ---- */
const CSS=`#auth{position:fixed;inset:0;z-index:99999;background:#0e0e10;color:#f2f4f7;display:flex;align-items:center;justify-content:center;padding:20px;font-family:system-ui,sans-serif}
#auth .box{width:100%;max-width:340px;text-align:center}
#auth h1{letter-spacing:.25em;margin:0 0 4px;font-size:32px;font-weight:900}#auth h1 b{color:#d1ff42}
#auth p{color:#9096a0;font-size:14px;margin:0 0 24px;line-height:1.5}
#auth input{width:100%;box-sizing:border-box;background:#18181b;border:1px solid #2b2b30;color:#f2f4f7;border-radius:14px;padding:14px 16px;font-size:17px;margin-bottom:10px;text-align:center;letter-spacing:.08em;outline:none;-webkit-appearance:none}
#auth input:focus{border-color:#d1ff42}
#auth button{width:100%;border:0;border-radius:14px;padding:14px;font-size:16px;font-weight:800;background:#d1ff42;color:#12160a;cursor:pointer;letter-spacing:.04em}
#auth .err{color:#ff7b7b;font-size:13px;min-height:18px;margin-bottom:10px}`;
const st=document.createElement('style');st.textContent=CSS;document.head.appendChild(st);

function overlay(html){let a=$('#auth');if(!a){a=document.createElement('div');a.id='auth';document.body.appendChild(a)}a.innerHTML=`<div class="box">${html}</div>`;return a}
const closeOv=()=>{const a=$('#auth');if(a)a.remove()};

/* ---- Token UI ---- */
function tokenUI(){return new Promise(res=>{
 const draw=(err='')=>{overlay(`
  <h1>MIS<b>TER</b></h1>
  <p>Inserisci il token ricevuto<br>dall'amministratore</p>
  <div class="err">${esc(err)}</div>
  <input id="tk_in" type="text" placeholder="il tuo token" autocomplete="off" autocorrect="off" autocapitalize="none" spellcheck="false">
  <button id="tk_go">Entra →</button>`);
  const inp=$('#tk_in');
  if(inp)setTimeout(()=>inp.focus(),80);
  $('#tk_go').onclick=async()=>{
   const token=$('#tk_in').value.trim().toLowerCase();
   if(!token)return draw('Inserisci il token');
   $('#tk_go').textContent='...';$('#tk_go').disabled=true;
   const {data,error}=await sb.rpc('validate_token',{p_token:token});
   if(error||!data||!data.valid)return draw('Token non riconosciuto');
   res({token,...data})
  };
  inp&&inp.addEventListener('keydown',e=>e.key==='Enter'&&$('#tk_go').click())};
 draw()})}

/* ---- Sessione ---- */
function getSession(){try{return JSON.parse(localStorage.getItem(AUTH_KEY))}catch(e){return null}}
function setSession(s){try{localStorage.setItem(AUTH_KEY,JSON.stringify(s))}catch(e){}}

let authP=null;
function ensureAuth(){return authP||(authP=(async()=>{
 let sess=getSession();
 if(sess){
  // Rivalida il token al boot (in background, non blocca)
  sb.rpc('validate_token',{p_token:sess.token}).then(({data})=>{if(!data||!data.valid){localStorage.removeItem(AUTH_KEY);location.reload()}});
 } else {
  sess=await tokenUI();
  setSession(sess);
  closeOv();
 }
 ME={id:sess.token,role:sess.role||'player',pid:sess.pid||null,name:sess.name||null};
 window.MISTER_ME=ME;
 // Auto-crea link giocatore se non esiste
 if(ME.pid){
  sb.from('docs').select('id').eq('path','links/'+ME.id).maybeSingle().then(({data})=>{
   if(!data)sb.from('docs').upsert({path:'links/'+ME.id,col:'links',id:ME.id,data:{id:ME.id,p:ME.pid}});
  });
 }
 return ME})())}

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

/* ---- Admin: token per giocatori ---- */
window.MisterTokenAdmin={
 async listTokens(){
  const {data}=await sb.from('invites').select('code,role,pid').eq('role','player');
  return data||[];
 },
 async createToken(adminToken,pid){
  const {data,error}=await sb.rpc('create_player_token',{p_admin_token:adminToken,p_pid:pid});
  if(error)throw new Error(error.message);
  return data;
 },
 async revokeToken(adminToken,pid){
  const {data,error}=await sb.rpc('revoke_player_token',{p_admin_token:adminToken,p_pid:pid});
  if(error)throw new Error(error.message);
  return data;
 }
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
  const {error}=await sb.from('push_subs').upsert({endpoint:sub.endpoint,user_id:ME.id,sub:sub.toJSON()});
  if(error)throw error;return true},
 async endpoint(){if(!this.supported())return null;const reg=await navigator.serviceWorker.ready;const sub=await reg.pushManager.getSubscription();return sub?sub.endpoint:null},
 async getPrefs(){const ep=await this.endpoint();if(!ep)return{};const {data,error}=await sb.from('push_subs').select('prefs').eq('endpoint',ep).maybeSingle();if(error)throw error;return(data&&data.prefs)||{}},
 async setPrefs(prefs){const ep=await this.endpoint();if(!ep)throw new Error('Attiva prima le notifiche');const {error}=await sb.from('push_subs').update({prefs}).eq('endpoint',ep);if(error)throw error;return true},
 async notify(title,body,url,type){const {data,error}=await sb.functions.invoke('notify',{body:{title,body,url,type:type||null}});if(error)throw error;return data}
};
if('serviceWorker' in navigator)navigator.serviceWorker.register('sw.js').catch(()=>{});
})();
