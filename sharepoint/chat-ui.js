/* =============================================================================
 * chat-ui.js  --  QA chat overlay (browser side), Tadori-style full-screen UI
 * -----------------------------------------------------------------------------
 * Deployed to an SPO document library; fetched + injected by broker.ps1 via CDP.
 * Runs inside the authenticated SharePoint page, talks to SPO REST with the
 * browser's own session (credentials: 'include'). No secrets here.
 *
 * Layout (mirrors trie0000/tadori): full-screen root, left = session history
 * (grouped by SessionId), right = chat thread with Markdown-rendered answers +
 * bottom composer. New questions go to the ACTIVE session (broker's injected
 * sessionId, the only one a running broker answers); older sessions are view-only.
 *
 * broker injects window.__QA_CONFIG__ = { listTitle, sessionId, pollIntervalMs, webUrl }
 * BEFORE evaluating this file.
 * ========================================================================== */
(function () {
  var ROOT_ID = 'qa-root';
  if (window.__QA_UI_MOUNTED__ && document.getElementById(ROOT_ID)) { return; }  // idempotent
  window.__QA_UI_MOUNTED__ = true;

  var CFG  = window.__QA_CONFIG__ || {};
  var WEB  = String(CFG.webUrl || location.origin).replace(/\/+$/, '');
  var LIST = CFG.listTitle || 'QA_PoC';
  var POLL = CFG.pollIntervalMs || 2500;
  // The broker (re-)injects its current run's sessionId on every load, so it is the
  // source of truth: a broker restart => new session. Fall back to sessionStorage only
  // when the broker didn't inject one (broker not running).
  var SID  = CFG.sessionId || sessionStorage.getItem('qa_sid');
  sessionStorage.setItem('qa_sid', SID);
  var BYLIST = "/_api/web/lists/getbytitle('" + encodeURIComponent(LIST) + "')";

  // broker advertises: mode, the chat models you can pick, and the source kinds present.
  var MODE      = CFG.mode || 'local';
  var MODELS    = [].concat(CFG.models || []).map(String).filter(Boolean);
  var DEF_MODEL = String(CFG.defaultModel || MODELS[0] || '');
  var SCOPES    = [].concat(CFG.scopes || []).map(String).filter(Boolean);   // raw kinds; labels below
  var KIND_LABEL = { mail: 'メール', onenote: 'OneNote', pptx: 'PPTX', transcript: '会議', doc: '文書' };
  function scopeLabel(k) { return KIND_LABEL[k] || k; }
  var selModel = localStorage.getItem('qa:model') || DEF_MODEL;
  if (MODELS.length && MODELS.indexOf(selModel) < 0) { selModel = DEF_MODEL || MODELS[0]; }
  var selScope = localStorage.getItem('qa:scope') || '';                     // '' = all sources
  if (selScope && SCOPES.indexOf(selScope) < 0) { selScope = ''; }

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

  // ---- Markdown -> HTML (read-only, tadori src/lib/markdown parity + GFM tables) ----
  // Input is LLM-generated text: escape HTML first, then build only our own tags (XSS-safe).
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function mdInline(s) {
    var out = s;
    out = out.replace(/`([^`]+)`/g, function (_m, c) { return '<code>' + c + '</code>'; });
    out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    out = out.replace(/\*([^*\n]+)\*/g, '<em>$1</em>');
    out = out.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
      function (_m, t, u) { return '<a href="' + u + '" target="_blank" rel="noopener noreferrer">' + t + '</a>'; });
    return out;
  }
  var BLOCK_START = /^(#{1,6}\s|```|>\s?|\s*[-*+]\s|\s*\d+\.\s)/;
  function isTableSep(line) { return /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$/.test(line); }
  function splitRow(line) { return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(function (c) { return c.trim(); }); }
  function nestedList(items, tag) {
    if (!items.length) { return ''; }
    var min = Math.min.apply(null, items.map(function (x) { return x.depth; }));
    var norm = items.map(function (x) { return { depth: Math.max(0, x.depth - min), text: x.text }; });
    var html = '', depth = -1;
    norm.forEach(function (it) {
      if (depth < 0) { html += '<' + tag + '><li>' + mdInline(esc(it.text)); depth = it.depth; }
      else if (it.depth > depth) { for (var d = depth; d < it.depth; d++) { html += '<' + tag + '><li>'; } html += mdInline(esc(it.text)); depth = it.depth; }
      else if (it.depth < depth) { for (var e = depth; e > it.depth; e--) { html += '</li></' + tag + '>'; } html += '</li><li>' + mdInline(esc(it.text)); depth = it.depth; }
      else { html += '</li><li>' + mdInline(esc(it.text)); }
    });
    while (depth >= 0) { html += '</li></' + tag + '>'; depth--; }
    return html;
  }
  function renderMarkdown(md) {
    var lines = String(md == null ? '' : md).replace(/\r\n/g, '\n').split('\n');
    var out = [], i = 0;
    while (i < lines.length) {
      var line = lines[i];
      if (/^```/.test(line)) {                                   // code fence
        var buf = []; i++;
        while (i < lines.length && !/^```/.test(lines[i])) { buf.push(lines[i]); i++; }
        i++; out.push('<pre><code>' + esc(buf.join('\n')) + '</code></pre>'); continue;
      }
      var h = /^(#{1,6})\s+(.*)$/.exec(line);                    // heading
      if (h) { out.push('<h' + h[1].length + '>' + mdInline(esc(h[2])) + '</h' + h[1].length + '>'); i++; continue; }
      if (/^\s*([-*_])\1{2,}\s*$/.test(line)) { out.push('<hr>'); i++; continue; }   // rule
      if (line.indexOf('|') >= 0 && i + 1 < lines.length && isTableSep(lines[i + 1])) {   // GFM table
        var header = splitRow(line); i += 2; var rows = [];
        while (i < lines.length && lines[i].indexOf('|') >= 0 && !/^\s*$/.test(lines[i])) { rows.push(splitRow(lines[i])); i++; }
        out.push('<table class="qa-tbl"><thead><tr>' + header.map(function (c) { return '<th>' + mdInline(esc(c)) + '</th>'; }).join('') +
          '</tr></thead><tbody>' + rows.map(function (r) { return '<tr>' + r.map(function (c) { return '<td>' + mdInline(esc(c)) + '</td>'; }).join('') + '</tr>'; }).join('') + '</tbody></table>');
        continue;
      }
      if (/^>\s?/.test(line)) {                                  // blockquote
        var qb = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) { qb.push(lines[i].replace(/^>\s?/, '')); i++; }
        out.push('<blockquote>' + mdInline(esc(qb.join(' '))) + '</blockquote>'); continue;
      }
      if (/^\s*[-*+]\s+/.test(line)) {                           // bullet list
        var ul = [];
        while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
          var mu = /^([ \t]*)[-*+]\s+(.*)$/.exec(lines[i]); ul.push({ depth: Math.floor(mu[1].replace(/\t/g, '  ').length / 2), text: mu[2] }); i++;
        }
        out.push(nestedList(ul, 'ul')); continue;
      }
      if (/^\s*\d+\.\s+/.test(line)) {                           // numbered list
        var ol = [];
        while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
          var mo = /^([ \t]*)\d+\.\s+(.*)$/.exec(lines[i]); ol.push({ depth: Math.floor(mo[1].replace(/\t/g, '  ').length / 2), text: mo[2] }); i++;
        }
        out.push(nestedList(ol, 'ol')); continue;
      }
      if (/^\s*$/.test(line)) { i++; continue; }                 // blank
      var pb = [];                                               // paragraph
      while (i < lines.length && !/^\s*$/.test(lines[i]) && !BLOCK_START.test(lines[i]) &&
             !(lines[i].indexOf('|') >= 0 && i + 1 < lines.length && isTableSep(lines[i + 1]))) { pb.push(lines[i]); i++; }
      out.push('<p>' + mdInline(esc(pb.join('\n'))).replace(/\n/g, '<br>') + '</p>');
    }
    return out.join('\n');
  }

  // ---- styles (Tadori design tokens; light + dark) --------------------------
  var css =
    '#qa-root{--ink:#2a2a26;--ink-3:#7a766c;--ink-4:#a8a39a;--paper:#fafaf7;--paper-2:#f3f1ea;--paper-2s:#ece8de;--paper-3:#e8e4d8;' +
    '--line:rgba(42,42,38,.12);--line-s:rgba(42,42,38,.18);--accent:#7a8a78;--accent-soft:rgba(122,138,120,.18);--accent-strong:#5e6f5c;' +
    '--danger:#b8534a;--danger-soft:rgba(184,83,74,.12);--ok:#2f6f5e;--hl:rgba(196,174,96,.45);' +
    '--font:"Meiryo","Hiragino Sans","Yu Gothic UI",-apple-system,"Segoe UI",system-ui,sans-serif;' +
    '--mono:ui-monospace,"Cascadia Mono","Consolas",monospace;' +
    'position:fixed;inset:0;z-index:2147483600;display:flex;flex-direction:column;height:100vh;' +
    'background:var(--paper);color:var(--ink);font-family:var(--font);font-size:15px;line-height:1.75;}' +
    '#qa-root[data-theme="dark"]{--ink:#e8e4d8;--ink-3:#a8a39a;--ink-4:#7a766c;--paper:#1d1b18;--paper-2:#25231f;--paper-2s:#2c2a25;--paper-3:#3a3731;--line:rgba(232,228,216,.14);--line-s:rgba(232,228,216,.22);}' +
    '#qa-root *{box-sizing:border-box;}' +
    // topbar
    '.qa-top{display:flex;align-items:center;gap:10px;height:46px;padding:0 16px;border-bottom:1px solid var(--line);flex:0 0 auto;background:var(--paper);}' +
    '.qa-brand{display:flex;align-items:center;gap:8px;font-size:16px;font-weight:600;}' +
    '.qa-brand .mk{font-family:var(--mono);color:var(--accent-strong);font-size:19px;}' +
    '.qa-brand .sub{font-size:11px;color:var(--ink-3);font-weight:400;}' +
    '.qa-sp{flex:1;}' +
    '.qa-chip{display:inline-flex;align-items:center;gap:6px;height:26px;padding:0 10px;font-size:12px;border-radius:99px;border:1px solid var(--line-s);background:var(--paper-2);color:var(--ink-3);}' +
    '.qa-chip .dot{width:7px;height:7px;border-radius:50%;background:var(--ok);}' +
    '.qa-chip .mono{font-family:var(--mono);color:var(--ink);}' +
    '.qa-ib{width:30px;height:30px;display:inline-flex;align-items:center;justify-content:center;border:none;background:transparent;color:var(--ink-3);border-radius:6px;cursor:pointer;}' +
    '.qa-ib:hover{background:var(--paper-2);color:var(--ink);}' +
    // main split
    '.qa-main{flex:1;min-height:0;display:flex;}' +
    '.qa-side{width:270px;flex:0 0 auto;border-right:1px solid var(--line);background:var(--paper-2);display:flex;flex-direction:column;overflow:hidden;}' +
    '.qa-side-head{display:flex;align-items:stretch;gap:8px;padding:12px;}' +
    '.qa-newsess{flex:1;display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:8px 12px;font:inherit;font-size:13px;font-weight:600;color:#fff;background:var(--accent);border:1px solid var(--accent);border-radius:8px;cursor:pointer;}' +
    '.qa-newsess:hover{background:var(--accent-strong);border-color:var(--accent-strong);}' +
    '.qa-searchbtn{flex:0 0 auto;width:38px;display:inline-flex;align-items:center;justify-content:center;background:var(--paper-2);border:1px solid var(--line-s);border-radius:8px;color:var(--ink-3);cursor:pointer;}' +
    '.qa-searchbtn:hover{color:var(--accent-strong);border-color:var(--accent-strong);background:var(--accent-soft);}' +
    '.qa-search{margin:0 12px 8px;padding:7px 10px;font:inherit;font-size:12px;color:var(--ink);background:var(--paper);border:1px solid var(--line-s);border-radius:7px;outline:none;}' +
    '.qa-search:focus{border-color:var(--accent);}' +
    '.qa-side-list{flex:1;min-height:0;overflow-y:auto;padding:0 8px 12px;display:flex;flex-direction:column;gap:2px;}' +
    '.qa-sess-empty{padding:14px;font-size:12px;color:var(--ink-4);text-align:center;}' +
    '.qa-sess{display:flex;align-items:flex-start;gap:9px;padding:8px 10px;border-radius:8px;cursor:pointer;color:var(--ink);}' +
    '.qa-sess:hover{background:var(--paper-3);}' +
    '.qa-sess.is-active{background:var(--accent-soft);}' +
    '.qa-sess-ic{flex:0 0 auto;color:var(--ink-4);display:inline-flex;margin-top:1px;}' +
    '.qa-sess.is-active .qa-sess-ic{color:var(--accent-strong);}' +
    '.qa-sess-body{flex:1;min-width:0;}' +
    '.qa-sess-t{font-size:13px;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}' +
    '.qa-sess.is-active .qa-sess-t{color:var(--accent-strong);font-weight:600;}' +
    '.qa-sess-m{font-size:11px;color:var(--ink-3);margin-top:2px;}' +
    '.qa-sess-del{flex:0 0 auto;display:none;align-items:center;justify-content:center;width:24px;height:24px;padding:0;border:none;background:transparent;color:var(--ink-4);border-radius:6px;cursor:pointer;}' +
    '.qa-sess:hover .qa-sess-del{display:inline-flex;}' +
    '.qa-sess-del:hover{color:var(--danger);background:var(--danger-soft);}' +
    // content
    '.qa-content{flex:1;min-width:0;display:flex;flex-direction:column;background:var(--paper);}' +
    '.qa-thread{flex:1;min-height:0;overflow:auto;padding:24px 24px 8px;}' +
    '.qa-turn{max-width:760px;margin:0 auto 28px;}' +
    '.qa-q{margin-left:auto;max-width:80%;width:fit-content;background:var(--accent-soft);color:var(--ink);padding:10px 12px;border-radius:8px 8px 2px 8px;white-space:pre-wrap;word-break:break-word;}' +
    '.qa-a{display:flex;gap:10px;margin-top:14px;}' +
    '.qa-av{flex:0 0 auto;width:28px;height:28px;border-radius:50%;background:var(--accent-soft);color:var(--accent-strong);font-family:var(--mono);display:flex;align-items:center;justify-content:center;}' +
    '.qa-ab{flex:1;min-width:0;}' +
    '.qa-ans{color:var(--ink);line-height:1.85;overflow-wrap:anywhere;}' +
    '.qa-ans>*:first-child{margin-top:0;}.qa-ans>*:last-child{margin-bottom:0;}' +
    '.qa-ans p{margin:.5em 0;}.qa-ans h1,.qa-ans h2,.qa-ans h3,.qa-ans h4{margin:1em 0 .4em;line-height:1.35;}' +
    '.qa-ans h1{font-size:1.3em;}.qa-ans h2{font-size:1.18em;}.qa-ans h3{font-size:1.07em;}.qa-ans h4{font-size:1em;}' +
    '.qa-ans ul,.qa-ans ol{margin:.4em 0;padding-left:1.4em;}.qa-ans li{margin:.2em 0;}' +
    '.qa-ans code{font-family:var(--mono);font-size:.9em;background:var(--paper-2s);padding:1px 5px;border-radius:4px;}' +
    '.qa-ans pre{background:var(--paper-2s);padding:10px 12px;border-radius:6px;overflow:auto;}.qa-ans pre code{background:none;padding:0;}' +
    '.qa-ans blockquote{margin:.5em 0;padding:2px 12px;border-left:3px solid var(--line-s);color:var(--ink-3);}' +
    '.qa-ans a{color:var(--accent-strong);}' +
    '.qa-ans .qa-tbl{border-collapse:collapse;margin:.6em 0;font-size:.95em;display:block;overflow-x:auto;max-width:100%;}' +
    '.qa-ans .qa-tbl th,.qa-ans .qa-tbl td{border:1px solid var(--line-s);padding:5px 9px;text-align:left;vertical-align:top;}' +
    '.qa-ans .qa-tbl th{background:var(--paper-2s);font-weight:600;}' +
    '.qa-gen{color:var(--ink-3);font-style:italic;}' +
    '.qa-timeout{color:var(--danger);}' +
    '.qa-err{color:var(--danger);background:var(--danger-soft);padding:8px 10px;border-radius:6px;}' +
    '.qa-meta{margin-top:8px;font-size:12px;color:var(--ink-3);}' +
    '.qa-meta .mono{font-family:var(--mono);}' +
    '.qa-empty{max-width:760px;margin:64px auto;text-align:center;color:var(--ink-4);}' +
    '.qa-empty .big{font-family:var(--mono);font-size:40px;color:var(--accent-soft);}' +
    // composer
    '.qa-comp{flex:0 0 auto;border-top:1px solid var(--line);padding:12px 24px 18px;background:var(--paper);}' +
    '.qa-form{position:relative;max-width:760px;margin:0 auto;line-height:0;}' +
    '.qa-input{width:100%;min-height:48px;max-height:40vh;padding:14px 56px 14px 16px;resize:none;font-family:inherit;font-size:15px;line-height:1.6;color:var(--ink);background:var(--paper-2);border:1px solid var(--line);border-radius:8px;outline:none;}' +
    '.qa-input:focus{background:var(--paper);border-color:var(--line-s);}' +
    '.qa-input::placeholder{color:var(--ink-4);}' +
    '.qa-input:disabled{opacity:.6;}' +
    '.qa-send{position:absolute;right:10px;bottom:9px;width:32px;height:32px;border:none;background:var(--accent);color:#fff;border-radius:6px;cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:16px;}' +
    '.qa-send:hover{background:var(--accent-strong);}.qa-send:disabled{opacity:.4;cursor:default;}' +
    '.qa-hint{max-width:760px;margin:6px auto 0;font-size:11px;color:var(--ink-4);line-height:1.4;}' +
    '.qa-ctrls{max-width:760px;margin:0 auto 8px;display:flex;flex-wrap:wrap;gap:16px;font-size:12px;color:var(--ink-3);}' +
    '.qa-ctrls label{display:inline-flex;align-items:center;gap:6px;}' +
    '.qa-ctrls select{font:inherit;font-size:12px;color:var(--ink);background:var(--paper-2);border:1px solid var(--line);border-radius:6px;padding:3px 7px;outline:none;cursor:pointer;}' +
    '.qa-ctrls select:focus{border-color:var(--line-s);}.qa-ctrls select:disabled{opacity:.55;cursor:default;}' +
    '.qa-src-wrap{margin-top:12px;}' +
    '.qa-src-h{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--ink-3);cursor:pointer;user-select:none;}' +
    '.qa-src-h svg{transition:transform .15s;}.qa-src-h.collapsed svg{transform:rotate(-90deg);}' +
    '.qa-src{margin-top:8px;}.qa-src.collapsed{display:none;}' +
    '.qa-hit{border:1px solid var(--line);border-radius:6px;padding:9px 11px;margin-bottom:6px;cursor:pointer;background:var(--paper);}' +
    '.qa-hit:hover,.qa-hit.is-open{background:var(--paper-2);border-color:var(--line-s);}' +
    '.qa-hit-head{display:flex;align-items:center;gap:8px;}' +
    '.qa-hit-n{flex:0 0 auto;font-family:var(--mono);font-size:11px;color:var(--accent-strong);background:var(--accent-soft);width:20px;height:20px;border-radius:4px;display:inline-flex;align-items:center;justify-content:center;}' +
    '.qa-hit-t{flex:1;min-width:0;font-size:13px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}' +
    'a.qa-hit-link{color:var(--accent-strong);text-decoration:none;}a.qa-hit-link:hover{text-decoration:underline;}' +
    '.qa-hit-k{flex:0 0 auto;font-size:11px;color:var(--ink-3);border:1px solid var(--line);border-radius:99px;padding:1px 8px;}' +
    '.qa-hit-sc{flex:0 0 auto;font-family:var(--mono);font-size:11px;color:var(--accent-strong);background:var(--accent-soft);padding:2px 6px;border-radius:4px;}' +
    '.qa-hit-snip{font-size:12px;color:var(--ink-3);margin-top:5px;line-height:1.6;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;}' +
    '.qa-hit.is-open .qa-hit-snip{display:none;}' +
    '.qa-hit-detail{margin-top:8px;padding-top:8px;border-top:1px solid var(--line);font-size:12.5px;line-height:1.8;white-space:pre-wrap;color:var(--ink);}';
  var style = document.createElement('style'); style.id = 'qa-style'; style.textContent = css; document.head.appendChild(style);

  // ---- DOM skeleton ---------------------------------------------------------
  var IC_PLUS = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>';
  var IC_SEARCH = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>';
  var IC_CHAT = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 11.5a8.4 8.4 0 0 1-8.5 8.5 8.5 8.5 0 0 1-3.8-.9L3 21l1.9-5.7a8.5 8.5 0 1 1 16.1-3.8z"/></svg>';
  var IC_TRASH = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m3 0v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 5v6m4-6v6"/></svg>';

  var root = document.createElement('div'); root.id = ROOT_ID;
  if (localStorage.getItem('qa:theme') === 'dark') { root.dataset.theme = 'dark'; }
  root.innerHTML =
    '<div class="qa-top">' +
      '<div class="qa-brand"><span class="mk">&#21839;</span><span>QA チャット <span class="sub">SharePoint ナレッジ</span></span></div>' +
      '<div class="qa-sp"></div>' +
      '<span class="qa-chip" title="現在の会話ID"><span class="dot"></span>会話 <span class="mono qa-sid"></span></span>' +
      '<button class="qa-ib qa-theme" title="ダークモード切替">&#9789;</button>' +
      '<button class="qa-ib qa-close" title="閉じる">&#10005;</button>' +
    '</div>' +
    '<div class="qa-main">' +
      '<div class="qa-side">' +
        '<div class="qa-side-head">' +
          '<button class="qa-newsess" title="新しい会話を開始">' + IC_PLUS + '<span>新しい会話</span></button>' +
          '<button class="qa-searchbtn" title="会話を検索">' + IC_SEARCH + '</button>' +
        '</div>' +
        '<input class="qa-search" type="text" placeholder="会話を検索…" style="display:none">' +
        '<div class="qa-side-list"></div>' +
      '</div>' +
      '<div class="qa-content">' +
        '<div class="qa-thread"></div>' +
        '<div class="qa-comp">' +
          '<div class="qa-ctrls">' +
            '<label>モデル <select class="qa-model"></select></label>' +
            '<label class="qa-scope-wrap">ソース <select class="qa-scope"></select></label>' +
          '</div>' +
          '<div class="qa-form">' +
            '<textarea class="qa-input" rows="1" placeholder="質問を入力（Enterで送信 / Shift+Enterで改行）"></textarea>' +
            '<button class="qa-send" title="送信">&#9658;</button>' +
          '</div>' +
          '<div class="qa-hint"></div>' +
        '</div>' +
      '</div>' +
    '</div>';
  document.body.appendChild(root);

  var sideList = root.querySelector('.qa-side-list');
  var threadEl = root.querySelector('.qa-thread');
  var input    = root.querySelector('.qa-input');
  var sendBtn  = root.querySelector('.qa-send');
  var hintEl   = root.querySelector('.qa-hint');
  var modelSel = root.querySelector('.qa-model');
  var scopeSel = root.querySelector('.qa-scope');
  var newsessBtn = root.querySelector('.qa-newsess');
  var searchBtn = root.querySelector('.qa-searchbtn');
  var searchInput = root.querySelector('.qa-search');
  root.querySelector('.qa-sid').textContent = String(SID).slice(0, 8);

  // model picker (from broker-advertised list); disabled when only one is available
  if (MODELS.length) {
    modelSel.innerHTML = MODELS.map(function (m) { return '<option value="' + esc(m) + '"' + (m === selModel ? ' selected' : '') + '>' + esc(m) + '</option>'; }).join('');
    if (MODELS.length < 2) { modelSel.disabled = true; }
  } else {
    modelSel.innerHTML = '<option value="">' + esc(DEF_MODEL || '既定') + '</option>'; modelSel.disabled = true;
  }
  // source picker: all-sources first, then each present kind. Local (no kinds) -> single "マニュアル".
  var scopeOpts = [{ value: '', label: SCOPES.length ? '全ソース' : 'マニュアル' }].concat(SCOPES.map(function (k) { return { value: k, label: scopeLabel(k) }; }));
  scopeSel.innerHTML = scopeOpts.map(function (o) { return '<option value="' + esc(o.value) + '"' + (o.value === selScope ? ' selected' : '') + '>' + esc(o.label) + '</option>'; }).join('');
  if (!SCOPES.length) { scopeSel.disabled = true; }
  modelSel.addEventListener('change', function () { selModel = modelSel.value; localStorage.setItem('qa:model', selModel); });
  scopeSel.addEventListener('change', function () { selScope = scopeSel.value; localStorage.setItem('qa:scope', selScope); });

  // ---- state ----------------------------------------------------------------
  var sessMap = {};          // sid -> { id, title, updatedAt, maxId, turns:[item...] }
  var sessOrder = [];        // sids, most-recent first
  var curSid = SID;          // the session you are IN: shown in the thread + where new questions post
  var searchQ = '';          // sidebar filter text
  var sentAt = {};           // "sid#turn" -> ms the question was posted (response-time base)
  var stamped = {};          // itemId -> DisplayedAt already written
  var pending = null;        // { turn, q } optimistic in-flight for the current session

  function newSessionId() { return 's-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 6); }
  function updateChip() { root.querySelector('.qa-sid').textContent = String(curSid).slice(0, 8); }
  // keep the current session in the list even before its first question is posted
  function ensureCur() {
    if (!sessMap[curSid]) { sessMap[curSid] = { id: curSid, turns: [], maxId: 0, updatedAt: new Date().toISOString(), title: '新しい会話' }; }
    if (sessOrder.indexOf(curSid) < 0) { sessOrder = [curSid].concat(sessOrder); }
  }
  function setCur(sid) {   // switch the session we're in (resume from history / new session)
    if (!sid || curSid === sid) { return; }
    curSid = sid; pending = null; updateChip(); ensureCur(); renderSidebar(); renderThread(); input.focus();
  }
  // delete a whole conversation: remove its list items (SharePoint moves them to the site
  // Recycle Bin, so it's recoverable). If it was the current one, start a fresh session.
  async function deleteSession(sid) {
    var s = sessMap[sid];
    var ids = s ? s.turns.map(function (t) { return t.Id; }).filter(function (id) { return typeof id === 'number'; }) : [];
    if (ids.length && !window.confirm('この会話を削除しますか？（' + ids.length + '件）\nSharePoint のごみ箱に移動します。')) { return; }
    for (var i = 0; i < ids.length; i++) {
      try { await rest(BYLIST + '/items(' + ids[i] + ')', { method: 'POST', headers: { 'X-HTTP-Method': 'DELETE', 'If-Match': '*' } }); } catch (e) {}
    }
    delete sessMap[sid];
    sessOrder = sessOrder.filter(function (x) { return x !== sid; });
    if (curSid === sid) { curSid = newSessionId(); pending = null; updateChip(); }
    ensureCur(); lastSig = null; renderSidebar(); renderThread();
    refresh();
  }

  // ---- helpers --------------------------------------------------------------
  function relTime(iso) {
    var t = Date.parse(iso); if (isNaN(t)) { return ''; }
    var s = Math.max(0, Math.round((Date.now() - t) / 1000));
    if (s < 60) { return s + '秒前'; }
    var m = Math.round(s / 60); if (m < 60) { return m + '分前'; }
    var h = Math.round(m / 60); if (h < 24) { return h + '時間前'; }
    return Math.round(h / 24) + '日前';
  }
  function titleOf(s) {
    var q = (s.turns[0] && s.turns[0].Question) ? String(s.turns[0].Question) : '';
    q = q.replace(/\s+/g, ' ').trim();
    if (!q) { return '新しい会話'; }
    return q.length > 34 ? q.slice(0, 34) + '…' : q;
  }
  function matchesSearch(s) {
    if (!searchQ) { return true; }
    var q = searchQ.toLowerCase();
    if (String(s.title || '').toLowerCase().indexOf(q) >= 0) { return true; }
    return s.turns.some(function (t) { return (String(t.Question || '') + ' ' + String(t.Answer || '')).toLowerCase().indexOf(q) >= 0; });
  }
  function nextTurn() {
    var s = sessMap[curSid]; var mx = 0;
    if (s) { s.turns.forEach(function (t) { if (t.Turn > mx) { mx = t.Turn; } }); }
    if (pending && pending.turn > mx) { mx = pending.turn; }
    return mx + 1;
  }

  // ---- data load: one query drives both the sidebar and the thread ----------
  async function refresh() {
    var rows;
    try {
      var res = await rest(BYLIST + "/items?$select=Id,Turn,Question,Answer,Status,SessionId,Created,AnsweredAt,DisplayedAt,Sources,Meta&$orderby=Id desc&$top=500");
      rows = (res && res.value) || [];
    } catch (e) { return; }                                   // transient; keep polling
    var map = {};
    rows.forEach(function (it) {
      var sid = it.SessionId || '(none)';
      if (!map[sid]) { map[sid] = { id: sid, turns: [], maxId: 0, updatedAt: it.Created }; }
      map[sid].turns.push(it);
      if (it.Id > map[sid].maxId) { map[sid].maxId = it.Id; }
      if (String(it.Created) > String(map[sid].updatedAt)) { map[sid].updatedAt = it.Created; }
    });
    Object.keys(map).forEach(function (sid) {
      map[sid].turns.sort(function (a, b) { return (a.Turn - b.Turn) || (a.Id - b.Id); });
      map[sid].title = titleOf(map[sid]);
    });
    sessMap = map; sessOrder = Object.keys(map);
    ensureCur();   // current session present even if it has no server items yet
    sessOrder.sort(function (a, b) { return String(sessMap[b].updatedAt).localeCompare(String(sessMap[a].updatedAt)); });
    // drop the optimistic bubble once the server reflects that turn
    if (pending && sessMap[curSid] && sessMap[curSid].turns.some(function (t) { return t.Turn === pending.turn; })) { pending = null; }
    // stamp DisplayedAt for freshly shown answers in the current session (latency measurement)
    (sessMap[curSid] ? sessMap[curSid].turns : []).forEach(function (it) {
      if (classify(it) === 'answered' && !it.DisplayedAt && !stamped[it.Id]) {
        stamped[it.Id] = true;
        rest(BYLIST + '/items(' + it.Id + ')', { method: 'POST', headers: { 'X-HTTP-Method': 'MERGE', 'If-Match': '*' }, body: { DisplayedAt: new Date().toISOString() } }).catch(function () {});
      }
    });
    renderSidebar();
    renderThread();
  }

  function renderSidebar() {
    ensureCur();
    var shown = sessOrder.filter(function (sid) { return sessMap[sid] && matchesSearch(sessMap[sid]); });
    if (!shown.length) {
      sideList.innerHTML = '<div class="qa-sess-empty">' + (searchQ ? '一致する会話がありません' : '会話がありません') + '</div>';
      return;
    }
    sideList.innerHTML = shown.map(function (sid) {
      var s = sessMap[sid];
      return '<div class="qa-sess' + (sid === curSid ? ' is-active' : '') + '" data-sid="' + esc(sid) + '">' +
        '<span class="qa-sess-ic">' + IC_CHAT + '</span>' +
        '<div class="qa-sess-body"><div class="qa-sess-t">' + esc(s.title) + '</div>' +
        '<div class="qa-sess-m">' + s.turns.length + '件 · ' + relTime(s.updatedAt) + '</div></div>' +
        '<button class="qa-sess-del" title="この会話を削除" data-del="' + esc(sid) + '">' + IC_TRASH + '</button></div>';
    }).join('');
  }

  var CHEVRON = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m6 9 6 6 6-6"/></svg>';
  function parseJson(s, dflt) { try { var v = JSON.parse(s); return v == null ? dflt : v; } catch (e) { return dflt; } }
  function fmtYen(y) {
    if (!(y > 0)) { return '¥0'; }
    if (y >= 1) { return '¥' + y.toFixed(1); }
    if (y >= 0.01) { return '¥' + y.toFixed(2); }
    return '¥' + y.toFixed(4);
  }
  function sourcesHtml(srcs) {
    if (!srcs.length) { return ''; }
    return '<div class="qa-src-wrap"><div class="qa-src-h">' + CHEVRON + ' 参照したソース（' + srcs.length + '）</div><div class="qa-src">' +
      srcs.map(function (s) {
        var kind = s.kind ? '<span class="qa-hit-k">' + esc(scopeLabel(s.kind)) + '</span>' : '';
        var score = (typeof s.score === 'number') ? '<span class="qa-hit-sc">' + s.score.toFixed(2) + '</span>' : '';
        var titleTxt = esc(s.title || ('ソース ' + (s.n || '')));
        // when the source has an original file, make the title a link that opens it in a new tab
        var title = (s.url && /^https?:\/\//i.test(s.url))
          ? '<a class="qa-hit-t qa-hit-link" href="' + esc(s.url) + '" target="_blank" rel="noopener noreferrer" title="元のソースを開く">' + titleTxt + ' &#8599;</a>'
          : '<div class="qa-hit-t">' + titleTxt + '</div>';
        return '<div class="qa-hit" data-body="' + esc(encodeURIComponent(s.body || s.snippet || '')) + '">' +
          '<div class="qa-hit-head"><span class="qa-hit-n">' + (s.n || '') + '</span>' +
          title + kind + score + '</div>' +
          '<div class="qa-hit-snip">' + esc(s.snippet || '') + '</div></div>';
      }).join('') + '</div></div>';
  }

  // An item is "answered" once it has an Answer/AnsweredAt, even if a Power Automate flow
  // later clobbers Status back to Detected (QA_PoC-detect fires on create) -- never key the
  // rendered state off Status alone, or a clobbered answer shows as "generating" forever.
  function classify(it) {
    var a = it.Answer ? String(it.Answer) : '';
    if (it.Status === 'Error' || /^\[error\]/.test(a)) { return 'error'; }
    if (it.Status === 'Answered' || it.AnsweredAt || a.trim()) { return 'answered'; }
    return 'pending';
  }
  function turnHtml(it) {
    var ans, extra = '', metaLine = '';
    var cls = classify(it);
    if (cls === 'answered') {
      ans = '<div class="qa-ans">' + renderMarkdown(it.Answer || '') + '</div>';
      var meta = parseJson(it.Meta, null);
      var srcs = parseJson(it.Sources, []); if (!Array.isArray(srcs)) { srcs = []; }
      var parts = [];
      if (meta && meta.model) { parts.push('<span class="mono">' + esc(meta.model) + '</span>'); }
      if (srcs.length) { parts.push(srcs.length + '件参照'); }
      if (meta) {
        if (meta.costYen > 0) { parts.push('想定費用 <span class="mono">' + fmtYen(meta.costYen) + '</span>'); }
        else if (meta.promptTokens || meta.completionTokens) { parts.push('<span class="mono">' + ((meta.promptTokens || 0) + (meta.completionTokens || 0)) + '</span> tok'); }
      }
      if (it.Created && it.AnsweredAt) { var sc = (Date.parse(it.AnsweredAt) - Date.parse(it.Created)) / 1000; if (sc >= 0) { parts.push('応答 <span class="mono">' + sc.toFixed(1) + '秒</span>'); } }
      metaLine = parts.length ? '<div class="qa-meta">' + parts.join(' · ') + '</div>' : '';
      extra = sourcesHtml(srcs);
    } else if (cls === 'error') {
      ans = '<div class="qa-err">⚠ ' + esc((it.Answer || 'エラー').replace(/^\[error\]\s*/, '')) + '</div>';
    } else {
      var start = sentAt[it.SessionId + '#' + it.Turn] || Date.parse(it.Created) || Date.now();
      ans = '<div class="qa-ans"><span class="qa-gen" data-start="' + start + '">回答生成中… (0s)</span></div>';
    }
    return '<div class="qa-turn">' +
      '<div class="qa-q">' + esc(it.Question) + '</div>' +
      '<div class="qa-a"><div class="qa-av">&#21839;</div><div class="qa-ab">' + ans + metaLine + extra + '</div></div></div>';
  }

  var lastSig = null;
  function renderThread() {
    ensureCur();
    var s = sessMap[curSid];
    var turns = s ? s.turns.slice() : [];
    if (pending && !turns.some(function (t) { return t.Turn === pending.turn; })) {
      turns.push({ Id: 'pending', Turn: pending.turn, Question: pending.q, Status: 'Pending', SessionId: curSid, Created: null });
    }
    // every session is resumable now (the broker answers all sessions), so the composer is always on
    input.disabled = false; sendBtn.disabled = false;
    hintEl.textContent = 'Enter で送信 · Shift+Enter で改行 · モデルはいつでも変更可 · 回答は Markdown';
    // skip the rebuild when nothing render-relevant changed, so a user's expanded source card
    // (added to the DOM on click) is not wiped on the next 2.5s poll.
    var sig = curSid + '|' + turns.map(function (t) { return t.Id + ':' + classify(t) + ':' + ((t.Answer || '').length) + ':' + ((t.Sources || '').length); }).join(',');
    if (sig === lastSig && threadEl.childElementCount) { return; }
    lastSig = sig;
    if (!turns.length) {
      threadEl.innerHTML = '<div class="qa-empty"><div class="big">&#21839;</div><div>質問を入力して会話を始めましょう。</div></div>';
    } else {
      var atBottom = threadEl.scrollHeight - threadEl.scrollTop - threadEl.clientHeight < 80;
      threadEl.innerHTML = turns.map(function (it) { return turnHtml(it); }).join('');
      if (atBottom) { threadEl.scrollTop = threadEl.scrollHeight; }
    }
  }

  // live "生成中 (Ns)" counter. If a question runs far past any real answer time the broker is
  // likely stopped/killed mid-answer, so give up counting and show a stopped message instead of
  // spinning forever. (The broker also reclaims orphaned in-flight items on its next start.)
  var GEN_TIMEOUT = 180;   // seconds
  setInterval(function () {
    var els = root.querySelectorAll('.qa-gen[data-start]');
    for (var k = 0; k < els.length; k++) {
      var secs = Math.max(0, Math.round((Date.now() - (+els[k].getAttribute('data-start'))) / 1000));
      if (secs >= GEN_TIMEOUT) {
        els[k].removeAttribute('data-start');
        els[k].classList.remove('qa-gen'); els[k].classList.add('qa-timeout');
        els[k].textContent = '応答が返りませんでした（broker が停止している可能性）。再送信してください。';
      } else {
        els[k].textContent = '回答生成中… (' + secs + 's)';
      }
    }
  }, 1000);

  // ---- send (posts to the current session; broker answers any session) ------
  async function send() {
    var q = input.value.trim(); if (!q) { return; }
    input.value = ''; autosize();
    var t = nextTurn();
    var sid = curSid;
    sentAt[sid + '#' + t] = Date.now();
    pending = { turn: t, q: q };
    renderThread();
    try {
      await rest(BYLIST + '/items', { method: 'POST', body: { Title: q.slice(0, 50), Question: q, SessionId: sid, Turn: t, Status: 'Pending', Model: selModel, Scope: selScope } });
    } catch (e) {
      pending = null; renderThread();
      threadEl.insertAdjacentHTML('beforeend', '<div class="qa-turn"><div class="qa-a"><div class="qa-av">&#21839;</div><div class="qa-ab"><div class="qa-err">送信失敗: ' + esc(e.message) + '</div></div></div></div>');
      return;
    }
    refresh();
  }
  function autosize() { input.style.height = 'auto'; input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.4) + 'px'; }

  // ---- events ---------------------------------------------------------------
  sideList.addEventListener('click', function (e) {
    var del = e.target.closest ? e.target.closest('.qa-sess-del') : null;
    if (del) { e.stopPropagation(); deleteSession(del.getAttribute('data-del')); return; }
    var card = e.target.closest ? e.target.closest('.qa-sess') : null;
    if (!card) { return; }
    setCur(card.getAttribute('data-sid'));   // resume that conversation
  });
  newsessBtn.addEventListener('click', function () { setCur(newSessionId()); });
  searchBtn.addEventListener('click', function () {
    var show = searchInput.style.display === 'none';
    searchInput.style.display = show ? '' : 'none';
    if (show) { searchInput.focus(); } else { searchInput.value = ''; searchQ = ''; renderSidebar(); }
  });
  searchInput.addEventListener('input', function () { searchQ = searchInput.value.trim(); renderSidebar(); });
  // source cards: collapse the whole block, or expand one card to its full body
  threadEl.addEventListener('click', function (e) {
    if (e.target.closest && e.target.closest('a')) { return; }   // let a source link open; don't toggle
    var h = e.target.closest ? e.target.closest('.qa-src-h') : null;
    if (h) { h.classList.toggle('collapsed'); if (h.nextElementSibling) { h.nextElementSibling.classList.toggle('collapsed'); } return; }
    var hit = e.target.closest ? e.target.closest('.qa-hit') : null;
    if (!hit) { return; }
    if (hit.classList.contains('is-open')) {
      hit.classList.remove('is-open'); var d = hit.querySelector('.qa-hit-detail'); if (d) { d.remove(); }
    } else {
      hit.classList.add('is-open');
      if (!hit.querySelector('.qa-hit-detail')) {
        var body = ''; try { body = decodeURIComponent(hit.getAttribute('data-body') || ''); } catch (x) { body = hit.getAttribute('data-body') || ''; }
        var el = document.createElement('div'); el.className = 'qa-hit-detail'; el.textContent = body; hit.appendChild(el);
      }
    }
  });
  sendBtn.addEventListener('click', send);
  input.addEventListener('input', autosize);
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) {
      if (e.isComposing || e.keyCode === 229) { return; }      // don't send on IME confirm Enter
      e.preventDefault(); send();
    }
  });
  root.querySelector('.qa-theme').addEventListener('click', function () {
    var dark = root.dataset.theme === 'dark';
    root.dataset.theme = dark ? '' : 'dark';
    localStorage.setItem('qa:theme', dark ? '' : 'dark');
  });
  root.querySelector('.qa-close').addEventListener('click', function () {
    window.__QA_UI_MOUNTED__ = false; root.remove();
    var st = document.getElementById('qa-style'); if (st) { st.remove(); }
  });

  // ---- boot -----------------------------------------------------------------
  async function loop() {
    if (!document.getElementById(ROOT_ID)) { return; }         // closed -> stop polling
    await refresh();
    setTimeout(loop, POLL);
  }
  renderThread();                                              // initial empty state
  input.focus();
  loop();
})();
