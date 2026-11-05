/* BubbleDeck 包上传流水线（pc/m 共用一份）
 * 依赖 base.html 的全局 copyTxt(text)
 * 结构契约：#dropzone(可点/可拖) #fileinput[multiple] #queue #batchbar #batchsum #batchon
 */
(function () {
  /* API 前缀参数化：admin 页面走默认 /admin；商家端页面在 <body data-upload-base="/biz"> 声明 */
  var BASE = document.body.getAttribute('data-upload-base') || '/admin';
  var dz = document.getElementById('dropzone'),
      fi = document.getElementById('fileinput'),
      q  = document.getElementById('queue'),
      bar = document.getElementById('batchbar'),
      sum = document.getElementById('batchsum'),
      bon = document.getElementById('batchon');
  if (!dz || !fi || !q || !bar) return;

  var items = [];            // {f, li, state: wait|run|ok|fail, pack}
  var running = false;
  var anyOk = false;

  /* 就地刷新包列表（列表已客户端渲染化；旧页面兜底整页刷新） */
  function refreshList() {
    if (window.BDList && window.BDList.refresh) window.BDList.refresh();
    else setTimeout(function () { location.reload(); }, 700);
  }

  function esc(s) {
    var d = document.createElement('div');
    d.textContent = s == null ? '' : String(s);
    return d.innerHTML;
  }

  /* 建议版本号：末段数字 +1（1.0 → 1.1）；解析不出就给 1.1 */
  function suggest(v) {
    var m = String(v || '').match(/^(.*?)(\d+)$/);
    return m ? m[1] + (parseInt(m[2], 10) + 1) : '1.1';
  }

  /* 冲突卡片点「改版本重传」：带走输入框里的新版本号重新入队 */
  q.addEventListener('click', function (e) {
    var b = e.target.closest ? e.target.closest('[data-retry]') : null;
    if (!b) return;
    var li = b.closest('.qitem');
    var it = null;
    for (var i = 0; i < items.length; i++) if (items[i].li === li) { it = items[i]; break; }
    if (!it || it.state !== 'fail') return;
    var inp = li.querySelector('.qver');
    var v = inp ? inp.value.trim() : '';
    if (!v) { inp && inp.focus(); return; }
    it.ver = v;
    it.state = 'wait';
    li.className = 'qitem wait';
    li.innerHTML = '<span class="qname">' + esc(it.f.name) + '</span><span class="qstat">排队中（v' + esc(v) + '）</span>';
    run();
  });

  function add(files) {
    for (var i = 0; i < files.length; i++) {
      (function (f) {
        var li = document.createElement('li');
        li.className = 'qitem wait';
        li.innerHTML = '<span class="qname">' + esc(f.name) + '</span><span class="qstat">排队中</span>';
        q.appendChild(li);
        items.push({ f: f, li: li, state: 'wait' });
      })(files[i]);
    }
    run();
  }

  function run() {
    if (running) return;
    running = true;
    next();
  }

  function next() {
    var it = null;
    for (var i = 0; i < items.length; i++) if (items[i].state === 'wait') { it = items[i]; break; }
    if (!it) {
      running = false;
      if (anyOk) refreshList();                     /* 队列清空且有成功项 → 就地刷新包列表 */
      summarize();
      return;
    }
    it.state = 'run';
    it.li.className = 'qitem run';
    it.li.querySelector('.qstat').textContent = '打包中…';
    var fd = new FormData();
    fd.append('file', it.f);
    var ai = document.getElementById('authorinput');
    if (ai && ai.value.trim()) fd.append('author', ai.value.trim());   /* 作者名：客户端主题页副标题 */
    if (it.ver) fd.append('version', it.ver);          /* 冲突重传时用户改的版本号 */
    fetch(BASE + '/api/packs/upload', { method: 'POST', body: fd, credentials: 'same-origin' })
      .then(function (r) {
        return r.json().then(function (j) { return { httpOk: r.ok, j: j }; },
                            function () { return { httpOk: false, j: null }; });
      })
      .then(function (res) {
        if (res.httpOk && res.j && res.j.code === 0) {
          var d = res.j.data;
          it.state = 'ok';
          anyOk = true;
          it.pack = d.name;
          it.li.className = 'qitem ok';
          it.li.innerHTML =
            '<span class="qname">' + esc(d.name) + ' v' + esc(d.version) + '</span>' +
            '<span class="qmeta">' + esc(d.size_cn) + ' · 默认下架 · ' +
            '<button type="button" class="minibtn" data-copy="' + esc(d.key) + '" data-label="复制 key">复制 key</button>' +
            ' · <button type="button" class="minibtn" data-copy="' + esc(d.url) + '" data-label="复制直链">复制直链</button></span>';
        } else {
          it.state = 'fail';
          it.li.className = 'qitem fail';
          var msg = (res.j && res.j.msg) || '上传失败';
          if (res.j && res.j.code === 2 && res.j.data) {   /* 冲突：给改版本重传的出路 */
            it.li.innerHTML =
              '<span class="qname">' + esc(res.j.data.name) + '</span>' +
              '<span class="qmeta">已存在 v' + esc(res.j.data.version) + ' · ' +
              '<input class="qver" type="text" value="' + esc(suggest(res.j.data.version)) +
                '" maxlength="32" aria-label="新版本号">' +
              '<button type="button" class="minibtn" data-retry>改版本重传</button></span>';
          } else {
            it.li.innerHTML = '<span class="qname">' + esc(it.f.name) + '</span>' +
                              '<span class="qmeta">' + esc(msg) + '</span>';
          }
        }
        summarize();
        next();
      })
      .catch(function () {
        it.state = 'fail';
        it.li.className = 'qitem fail';
        it.li.innerHTML = '<span class="qname">' + esc(it.f.name) + '</span><span class="qmeta">网络错误</span>';
        summarize();
        next();
      });
  }

  function summarize() {
    var ok = 0, fail = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i].state === 'ok') ok++;
      else if (items[i].state === 'fail') fail++;
    }
    if (ok + fail === 0) { bar.hidden = true; return; }
    bar.hidden = false;
    sum.textContent = ok + ' 成功' + (fail ? ' · ' + fail + ' 失败' : '');
    bon.hidden = ok === 0;
    bon.disabled = false;
    bon.textContent = '一键上架本批成功包';
  }

  /* 交互绑定 */
  dz.addEventListener('click', function () { fi.click(); });
  dz.addEventListener('dragover', function (e) { e.preventDefault(); dz.classList.add('over'); });
  dz.addEventListener('dragleave', function () { dz.classList.remove('over'); });
  dz.addEventListener('drop', function (e) {
    e.preventDefault();
    dz.classList.remove('over');
    if (e.dataTransfer && e.dataTransfer.files.length) add(e.dataTransfer.files);
  });
  fi.addEventListener('change', function () {
    if (fi.files.length) add(fi.files);
    fi.value = '';
  });

  /* 结果区点击：复制 key / 直链（事件委托，重绘的按钮也能用） */
  bar.addEventListener('click', function (e) {
    var b = e.target.closest ? e.target.closest('[data-copy]') : null;
    if (!b) return;
    copyTxt(b.getAttribute('data-copy'));
    b.textContent = '已复制';
    setTimeout(function () { b.textContent = b.getAttribute('data-label') || '复制'; }, 1200);
  });

  /* 一键上架本批成功包（JSON 接口，逐个串行；完成后列表就地刷新） */
  bon.addEventListener('click', function () {
    var packs = [];
    for (var i = 0; i < items.length; i++) if (items[i].state === 'ok' && items[i].pack) packs.push(items[i].pack);
    if (!packs.length) return;
    bon.disabled = true;
    bon.textContent = '上架中…';
    var chain = Promise.resolve();
    packs.forEach(function (p) {
      chain = chain.then(function () {
        var fd = new FormData();
        fd.append('name', p);
        fd.append('state', 'on');
        return fetch(BASE + '/api/packs/state', { method: 'POST', body: fd, credentials: 'same-origin' });
      });
    });
    chain.then(function () {
      bon.textContent = '已全部上架';
      refreshList();
    });
  });
})();
