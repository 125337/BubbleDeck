/* BubbleDeck 管理后台共享核心：请求封装 / 转义 / toast / 复制（pc 与 m 端共用，逻辑只有这一份） */
window.BD = (function () {
  function esc(s) {
    var d = document.createElement('div');
    d.textContent = s == null ? '' : String(s);
    return d.innerHTML;
  }

  /* toast：独立 bdtoast 元素与专属样式。
     严禁复用页面 .toast/#toast——那是服务端 flash 的样式，pc/m 两端定位不同，
     混用会导致 top+bottom 同时生效、元素被撑成通天条（已踩坑）。 */
  var _bt = null;
  function toast(msg) {
    if (!_bt) {
      _bt = document.createElement('div');
      _bt.id = 'bdtoast';
      _bt.setAttribute('role', 'status');
      document.body.appendChild(_bt);
      var st = document.createElement('style');
      st.textContent = '#bdtoast{position:fixed;top:24px;bottom:auto;left:50%;transform:translate(-50%,-10px);opacity:0;' +
        'pointer-events:none;background:var(--ink,#17161b);color:#f3f1ed;padding:11px 16px;border-radius:8px;' +
        'font-size:13px;max-width:min(92vw,480px);box-shadow:0 10px 26px rgba(23,22,27,.32);' +
        'transition:opacity .22s,transform .22s;z-index:9999}' +
        '#bdtoast.show{opacity:1;transform:translate(-50%,0)}';
      document.head.appendChild(st);
    }
    _bt.textContent = msg;
    requestAnimationFrame(function () { _bt.classList.add('show'); });
    clearTimeout(_bt._tm);
    _bt._tm = setTimeout(function () { _bt.classList.remove('show'); }, 2800);
  }

  /* POST 表单 → JSON；网络/解析失败统一返回 {code:-1}，调用方只判 code */
  function api(url, data) {
    var fd = new FormData();
    for (var k in data) fd.append(k, data[k]);
    return fetch(url, { method: 'POST', body: fd, credentials: 'same-origin' })
      .then(function (r) { return r.json().then(ok, fail); }, fail);
  }

  function get(url) {
    return fetch(url, { credentials: 'same-origin' })
      .then(function (r) { return r.json().then(ok, fail); }, fail);
  }

  function ok(j) { return j && typeof j.code === 'number' ? j : { code: -1, msg: '响应异常' }; }
  function fail() { return { code: -1, msg: '网络错误' }; }

  /* 复制文本；btn 传入时短暂变“已复制” */
  function copy(text, btn) {
    return copyTxt(text).then(function () {
      if (!btn) return;
      if (!btn._label) btn._label = btn.textContent;
      btn.textContent = '已复制';
      clearTimeout(btn._ct);
      btn._ct = setTimeout(function () { btn.textContent = btn._label; }, 1200);
    });
  }

  return { esc: esc, toast: toast, api: api, get: get, copy: copy };
})();
