/* =============================================================================
 * chat-ui.js  --  QA chat overlay (browser side)
 * -----------------------------------------------------------------------------
 * Deployed to an SPO document library; fetched + injected by broker.py via CDP.
 * Runs inside the authenticated SharePoint page, talks to SPO REST with the
 * browser's own session (credentials: 'include'). No secrets here.
 *
 * broker injects window.__QA_CONFIG__ = { listTitle, sessionId, pollIntervalMs, webUrl }
 * BEFORE evaluating this file.
 * ========================================================================== */
(function () {
  if (window.__QA_UI_MOUNTED__) { return; }   // idempotent (survives re-inject)
  window.__QA_UI_MOUNTED__ = true;

  var CFG  = window.__QA_CONFIG__ || {};
  var WEB  = String(CFG.webUrl || location.origin).replace(/\/+$/, '');
  var LIST = CFG.listTitle || 'QA_PoC';
  var POLL = CFG.pollIntervalMs || 2500;
  // session continuity across reloads; broker's id is the seed for a fresh run
  var SID  = sessionStorage.getItem('qa_sid') || CFG.sessionId;
  sessionStorage.setItem('qa_sid', SID);

  var BYLIST = "/_api/web/lists/getbytitle('" + encodeURIComponent(LIST) + "')";

  // ---- REST helpers (shared digest) ----------------------------------------
  var _digest = null, _digestExp = 0;
  async function digest() {
    if (_digest && Date.now() < _digestExp) { return _digest; }
    var r = await fetch(encodeURI(WEB + '/_api/contextinfo'), {
      method: 'POST', headers: { Accept: 'application/json;odata=nometadata' }, credentials: 'include'
    });
    var j = await r.json();
    _digest = j.FormDigestValue;
    _digestExp = Date.now() + ((j.FormDigestTimeoutSeconds || 1800) - 300) * 1000;
    return _digest;
  }
  async function rest(rel, opt) {
    opt = opt || {};
    var method = opt.method || 'GET';
    var headers = Object.assign({ Accept: 'application/json;odata=nometadata' }, opt.headers || {});
    if (opt.body != null) { headers['Content-Type'] = 'application/json;odata=nometadata'; }
    if (method !== 'GET') { headers['X-RequestDigest'] = await digest(); }
    var init = { method: method, headers: headers, credentials: 'include' };
    if (opt.body != null) { init.body = JSON.stringify(opt.body); }
    var r = await fetch(encodeURI(WEB + rel), init);
    if (r.status === 403 && method !== 'GET') {          // digest expired -> refresh once
      _digest = null; headers['X-RequestDigest'] = await digest();
      r = await fetch(encodeURI(WEB + rel), init);
    }
    var text = await r.text(); var json = null; try { json = JSON.parse(text); } catch (e) {}
    if (!r.ok) { throw new Error(method + ' ' + rel + ' -> ' + r.status + ' ' + text.slice(0, 200)); }
    return json;
  }

  // ---- styles + DOM ---------------------------------------------------------
  var css =
    '.qa-panel{position:fixed;right:20px;bottom:20px;width:360px;height:520px;z-index:2147483000;' +
    'display:flex;flex-direction:column;background:#fff;border:1px solid #d0d0d0;border-radius:10px;' +
    'box-shadow:0 8px 30px rgba(0,0,0,.18);font-family:"Meiryo","Segoe UI",system-ui,sans-serif;font-size:13px;color:#222}' +
    '.qa-head{padding:10px 12px;font-weight:700;border-bottom:1px solid #eee;display:flex;justify-content:space-between;align-items:center}' +
    '.qa-head small{font-weight:400;color:#888;font-size:11px}' +
    '.qa-body{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px}' +
    '.qa-msg{max-width:82%;padding:8px 10px;border-radius:10px;white-space:pre-wrap;word-break:break-word;line-height:1.5}' +
    '.qa-user{align-self:flex-end;background:#2f6f5e;color:#fff}' +
    '.qa-bot{align-self:flex-start;background:#f1f0ec;color:#222}' +
    '.qa-bot.qa-wait{color:#999;font-style:italic}' +
    '.qa-meta{align-self:flex-start;font-size:10px;color:#9a9a9a;margin-top:-4px;padding-left:4px}' +
    '.qa-foot{border-top:1px solid #eee;padding:8px;display:flex;gap:6px}' +
    '.qa-foot textarea{flex:1;resize:none;height:38px;max-height:120px;padding:8px;border:1px solid #d0d0d0;border-radius:8px;font:inherit}' +
    '.qa-foot button{width:38px;border:0;border-radius:8px;background:#2f6f5e;color:#fff;cursor:pointer;font-size:16px}' +
    '.qa-foot button:disabled{opacity:.4;cursor:default}' +
    '.qa-gear{border:0;background:transparent;cursor:pointer;font-size:15px;color:#888;padding:0 4px}' +
    '.qa-modal{position:fixed;inset:0;z-index:2147483001;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center}' +
    '.qa-modal-box{background:#fff;border-radius:10px;width:440px;max-width:92vw;max-height:88vh;overflow:auto;padding:16px;font-family:"Meiryo","Segoe UI",system-ui,sans-serif;font-size:13px;color:#222}' +
    '.qa-modal-h{font-weight:700;margin-bottom:4px}' +
    '.qa-modal-sub{font-size:11px;color:#888;margin-bottom:10px}' +
    '.qa-f{display:flex;flex-direction:column;gap:3px;margin-bottom:10px}' +
    '.qa-f span{font-size:11px;color:#666}' +
    '.qa-f input{padding:7px;border:1px solid #d0d0d0;border-radius:6px;font:inherit}' +
    '.qa-modal-ft{display:flex;justify-content:flex-end;gap:8px;margin-top:6px}' +
    '.qa-modal-ft button{height:32px;padding:0 14px;border:0;border-radius:6px;cursor:pointer}' +
    '.qa-save{background:#2f6f5e;color:#fff}.qa-cancel{background:#f1f0ec;color:#222}';
  var style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);

  var panel = document.createElement('div'); panel.className = 'qa-panel';
  panel.innerHTML =
    '<div class="qa-head"><span>QA チャット <small>PoC</small></span>' +
      '<span><button class="qa-gear" title="設定">⚙</button><small class="qa-sid"></small></span></div>' +
    '<div class="qa-body"></div>' +
    '<div class="qa-foot"><textarea placeholder="質問を入力 (Enterで送信)"></textarea><button title="送信">&#9658;</button></div>';
  document.body.appendChild(panel);

  var body = panel.querySelector('.qa-body');
  var input = panel.querySelector('textarea');
  var btn = panel.querySelector('button');
  panel.querySelector('.qa-sid').textContent = 'sid:' + String(SID).slice(0, 8);
  input.disabled = true; btn.disabled = true;

  function bubble(role, text, wait) {
    var d = document.createElement('div');
    d.className = 'qa-msg ' + (role === 'user' ? 'qa-user' : 'qa-bot') + (wait ? ' qa-wait' : '');
    d.textContent = text;
    body.appendChild(d); body.scrollTop = body.scrollHeight;
    return d;
  }
  function addMeta(afterEl, text) {   // small gray line under a bubble (response time)
    var m = document.createElement('div'); m.className = 'qa-meta'; m.textContent = text;
    afterEl.insertAdjacentElement('afterend', m);
    body.scrollTop = body.scrollHeight;
  }
  function fmt(ms) { return (ms / 1000).toFixed(1) + '秒'; }

  // ---- state ----------------------------------------------------------------
  var turn = 0;                 // last turn number used in this session
  var shown = {};               // itemId -> true (answer/error rendered)
  var waiting = {};             // turn -> placeholder bubble element
  var sentAt = {};              // turn -> ms when the question was sent (response-time base)
  var timers = {};              // turn -> live "生成中 (Ns)" counter interval id

  function stopTimer(t) { if (timers[t]) { clearInterval(timers[t]); delete timers[t]; } }

  async function send() {
    var q = input.value.trim(); if (!q) { return; }
    input.value = '';
    turn += 1; var myTurn = turn;
    bubble('user', q);
    sentAt[myTurn] = Date.now();
    waiting[myTurn] = bubble('bot', '回答生成中… (0s)', true);
    timers[myTurn] = setInterval(function () {           // live elapsed counter
      var ph = waiting[myTurn];
      if (ph) { ph.textContent = '回答生成中… (' + Math.round((Date.now() - sentAt[myTurn]) / 1000) + 's)'; }
    }, 1000);
    try {
      await rest(BYLIST + '/items', { method: 'POST', body: {
        Title: q.slice(0, 50), Question: q, SessionId: SID, Turn: myTurn, Status: 'Pending'
      }});
    } catch (e) {
      stopTimer(myTurn);
      if (waiting[myTurn]) { waiting[myTurn].textContent = '送信失敗: ' + e.message; waiting[myTurn].classList.remove('qa-wait'); delete waiting[myTurn]; }
    }
  }

  function render(it) {
    if (shown[it.Id]) { return; }
    if (it.Status === 'Answered') {
      shown[it.Id] = true;
      stopTimer(it.Turn);
      var ph = waiting[it.Turn];
      if (ph) { ph.textContent = it.Answer || ''; ph.classList.remove('qa-wait'); delete waiting[it.Turn]; }
      else { ph = bubble('bot', it.Answer || ''); }
      if (sentAt[it.Turn]) {                              // ⏱ end-to-end response time (send -> shown)
        addMeta(ph, '⏱ 応答 ' + fmt(Date.now() - sentAt[it.Turn]));
        delete sentAt[it.Turn];
      }
      // measurement: stamp DisplayedAt so broker can collect the UI-visible time
      rest(BYLIST + '/items(' + it.Id + ')', {
        method: 'POST', headers: { 'X-HTTP-Method': 'MERGE', 'If-Match': '*' },
        body: { DisplayedAt: new Date().toISOString() }
      }).catch(function () {});
    } else if (it.Status === 'Error') {
      shown[it.Id] = true;
      stopTimer(it.Turn);
      var ph2 = waiting[it.Turn];
      var msg = '⚠ ' + (it.Answer || 'エラー');
      if (ph2) { ph2.textContent = msg; ph2.classList.remove('qa-wait'); delete waiting[it.Turn]; }
      else { bubble('bot', msg); }
      if (sentAt[it.Turn]) { delete sentAt[it.Turn]; }
    }
  }

  async function poll() {
    try {
      var res = await rest(BYLIST + "/items?$select=Id,Turn,Answer,Status&$filter=SessionId eq '" + SID +
                           "'&$orderby=Turn asc&$top=200");
      var rows = (res && res.value) || [];
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].Turn > turn) { turn = rows[i].Turn; }
        render(rows[i]);
      }
    } catch (e) { /* transient; keep polling */ }
    setTimeout(poll, POLL);
  }

  async function init() {
    try {
      var res = await rest(BYLIST + "/items?$select=Id,Turn,Question,Answer,Status&$filter=SessionId eq '" + SID +
                           "'&$orderby=Turn asc&$top=200");
      var rows = (res && res.value) || [];
      rows.forEach(function (it) {
        if (it.Question) { bubble('user', it.Question); }
        if (it.Status === 'Answered') { bubble('bot', it.Answer || ''); shown[it.Id] = true; }
        else if (it.Status === 'Error') { bubble('bot', '⚠ ' + (it.Answer || '')); shown[it.Id] = true; }
        if (it.Turn > turn) { turn = it.Turn; }
      });
    } catch (e) { bubble('bot', '初期化エラー: ' + e.message); }
    input.disabled = false; btn.disabled = false; input.focus();
    poll();
  }

  // ---- settings screen (corp API search + segments URL) ---------------------
  // Saved to localStorage; the broker reads these via CDP to run corp-API search.
  var SFIELDS = [
    ['qa:segUrl',      'SPO セグメントURL（ベクトル化済み文書の場所）', 'https://<tenant>.sharepoint.com/sites/<site>/Shared%20Documents/Tadori'],
    ['qa:corpBase',    '社内API ベースURL（ゲートウェイ or リレー loopback）', 'http://127.0.0.1:18080'],
    ['qa:embedDeploy', '埋め込みデプロイ名', 'text-embedding-3-large'],
    ['qa:embedDim',    '埋め込み次元（dimensions）', '1024'],
    ['qa:apiVersion',  'API バージョン', '2024-02-01'],
    ['qa:chatDeploy',  '回答デプロイ名（chat）', 'gpt-4.1-mini'],
    ['qa:corpKey',     'api-key（このブラウザにのみ保存）', ''],
  ];
  function lsGet(k) { try { return localStorage.getItem(k) || ''; } catch (e) { return ''; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }

  var modal = document.createElement('div');
  modal.className = 'qa-modal'; modal.style.display = 'none';
  var rows = SFIELDS.map(function (f) {
    var typ = f[0] === 'qa:corpKey' ? 'password' : 'text';
    return '<label class="qa-f"><span>' + f[1] + '</span>' +
           '<input type="' + typ + '" data-k="' + f[0] + '" placeholder="' + f[2] + '"></label>';
  }).join('');
  modal.innerHTML = '<div class="qa-modal-box"><div class="qa-modal-h">設定（社内API検索）</div>' +
    '<div class="qa-modal-sub">ベクトル化済み文書(SPO)を社内API埋め込みで検索します。brokerがこの設定を読みます。</div>' +
    rows + '<div class="qa-modal-ft"><button class="qa-cancel">閉じる</button><button class="qa-save">保存</button></div></div>';
  document.body.appendChild(modal);

  function openSettings() {
    SFIELDS.forEach(function (f) { modal.querySelector('[data-k="' + f[0] + '"]').value = lsGet(f[0]); });
    modal.style.display = 'flex';
  }
  modal.querySelector('.qa-save').addEventListener('click', function () {
    SFIELDS.forEach(function (f) { lsSet(f[0], modal.querySelector('[data-k="' + f[0] + '"]').value.trim()); });
    modal.style.display = 'none';
  });
  modal.querySelector('.qa-cancel').addEventListener('click', function () { modal.style.display = 'none'; });
  modal.addEventListener('click', function (e) { if (e.target === modal) { modal.style.display = 'none'; } });
  panel.querySelector('.qa-gear').addEventListener('click', openSettings);

  btn.addEventListener('click', send);
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) {
      if (e.isComposing || e.keyCode === 229) { return; }   // IME 変換確定Enterを送信にしない
      e.preventDefault(); send();
    }
  });

  init();
})();
