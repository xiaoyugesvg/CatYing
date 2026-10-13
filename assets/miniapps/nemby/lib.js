/*!
 * 影视库 · 共享运行时
 *
 * 只依赖宿主注入的 window.ant：
 *   ant.source.*  取数据（宿主已配置的采集源）
 *   ant.player.*  播放
 *   ant.storage.* 站点选择、观看历史、跨页传参
 *   ant.ui.*      提示
 *   ant.tv.onKey  遥控器焦点
 */
(function () {
  'use strict';

  var App = (window.App = { site: null, sites: [] });

  /* ---------------- 工具 ---------------- */

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function qs(name) {
    var m = new RegExp('[?&]' + name + '=([^&]*)').exec(location.search);
    return m ? decodeURIComponent(m[1].replace(/\+/g, ' ')) : '';
  }

  /** 并发池。采集源在宿主侧的并发上限是 3，这里保守用 2。 */
  function pool(items, size, worker) {
    var results = new Array(items.length);
    var cursor = 0;
    function next() {
      if (cursor >= items.length) return Promise.resolve();
      var index = cursor++;
      return Promise.resolve()
        .then(function () { return worker(items[index], index); })
        .then(function (value) { results[index] = value; })
        .catch(function (e) { results[index] = { __error: e }; })
        .then(next);
    }
    var runners = [];
    for (var i = 0; i < Math.min(size, items.length); i++) runners.push(next());
    return Promise.all(runners).then(function () { return results; });
  }

  function errText(e) {
    if (!e) return '未知错误';
    return (e.code ? e.code + ' · ' : '') + (e.message || String(e));
  }

  function toast(message) {
    try { ant.ui.toast(message); } catch (e) { /* ui 权限缺失时静默 */ }
  }

  /* ---------------- 顶栏 ---------------- */

  function renderHeader(active) {
    var host = document.getElementById('app-header');
    if (!host) return;
    var tabs = [
      { id: 'home', name: '首页', href: 'index.html' },
      { id: 'library', name: '媒体库', href: 'library.html' },
      { id: 'search', name: '搜索', href: 'search.html' },
      { id: 'settings', name: '设置', href: 'settings.html' }
    ];
    host.className = 'header';
    host.innerHTML =
      '<div class="brand"><i>▶</i>影视库</div>' +
      '<nav class="nav">' +
      tabs.map(function (t) {
        return '<a data-focus href="' + t.href + '" class="' +
          (t.id === active ? 'on' : '') + '">' + t.name + '</a>';
      }).join('') +
      '</nav>' +
      '<button data-focus class="site-chip" id="site-chip">' +
      '<span>源</span><b>…</b></button>';

    var chip = document.getElementById('site-chip');
    if (chip) chip.addEventListener('click', switchSite);
  }

  function paintSiteChip() {
    var chip = document.getElementById('site-chip');
    if (!chip) return;
    var name = App.site ? App.site.name : '未配置';
    var tag = isCmsSite(App.site) ? '<span class="site-tag cms">CMS</span>' : '<span class="site-tag host">源</span>';
    chip.innerHTML = tag + '<b>' + esc(name) + '</b>';
  }

  /* ---------------- 源切换：树形分类面板 ---------------- */

  function siteGroupOf(site) {
    // 按站点自带group分组，树形显示；CMS源优先用site.group，没有则"未分组"
    if (site && site.sourceType === 'cms') return String(site.group || '未分组').trim();
    return String(site.group || site.category || site.type || site.groupName || '采集源').trim();
  }

  function buildSiteTree(sites) {
    var groupOrder = ['采集源', 'CMS源'];
    var groupMap = {};
    sites.forEach(function (site) {
      var g = siteGroupOf(site);
      if (!groupMap[g]) groupMap[g] = [];
      groupMap[g].push(site);
    });
    var tree = [];
    groupOrder.forEach(function (g) {
      if (groupMap[g] && groupMap[g].length) tree.push({ name: g, sites: groupMap[g] });
    });
    Object.keys(groupMap).forEach(function (g) {
      if (groupOrder.indexOf(g) < 0) tree.push({ name: g, sites: groupMap[g] });
    });
    return tree;
  }

  /* ---------------- 双源引擎：宿主源 + CMS源统一数据接口 ---------------- */

  // 判断是否 CMS 源
  function isCmsSite(site) {
    return site && site.sourceType === 'cms';
  }

  // CMS 源请求（直接用 ant.request，不走 T4 HTTP 代理，减少一层开销）
  function cmsFetch(site, params) {
    var url = new URL(site.cmsUrl);
    Object.keys(params || {}).forEach(function (key) {
      var value = params[key];
      if (value !== undefined && value !== null && String(value) !== '') {
        url.searchParams.set(key, String(value));
      }
    });
    return ant.request({
      url: url.toString(),
      timeout: 60000,
      headers: { Accept: 'application/json, text/plain, */*', 'User-Agent': 'okhttp/4.12.0' }
    }).then(function (response) {
      var statusCode = Number(response && response.statusCode || 0);
      var rawData = response && response.data;
      if (statusCode < 200 || statusCode >= 300) {
        var errorBody = typeof rawData === 'string' ? rawData : JSON.stringify(rawData || '');
        var e = new Error('CMS HTTP ' + statusCode + (errorBody ? ': ' + errorBody.slice(0, 160) : ''));
        e.code = 'CMS_HTTP_' + statusCode;
        throw e;
      }
      if (rawData && typeof rawData === 'object') return rawData;
      var body = String(rawData || '').replace(/^\uFEFF/, '').trim();
      try { return JSON.parse(body); }
      catch (err) {
        var candidate = body.replace(/^\s*<pre[^>]*>/i, '').replace(/<\/pre>\s*$/i, '').trim();
        var jsonp = candidate.match(/^[\w$]+\s*\((.*)\)\s*;?$/s);
        if (jsonp) candidate = jsonp[1].trim();
        try { return JSON.parse(candidate); }
        catch (_) {
          var pe = new Error('CMS 返回的不是 JSON：' + (body.slice(0, 180) || '空响应'));
          pe.code = 'CMS_INVALID_JSON';
          throw pe;
        }
      }
    });
  }

  function cmsUnwrap(payload) {
    if (payload && payload.data && typeof payload.data === 'object' &&
        (payload.data.list || payload.data.class || payload.data.classes)) {
      return payload.data;
    }
    return payload || {};
  }

  /* 修复CMS相对路径封面：把 /upload/xxx.jpg 拼接成 https://域名/upload/xxx.jpg */
  function fixCmsPics(site, list) {
    if (!site || !site.cmsUrl || !list || !list.length) return list;
    var base;
    try {
      var u = new URL(site.cmsUrl);
      base = u.protocol + '//' + u.host;
    } catch (e) { return list; }
    list.forEach(function (vod) {
      if (!vod) return;
      ['vod_pic', 'vod_pic_slide', 'vod_pic_thumb', 'vod_pic_screenshot'].forEach(function (key) {
        var pic = vod[key];
        if (pic && typeof pic === 'string' && !/^https?:\/\//i.test(pic) && !/^data:/i.test(pic)) {
          if (pic.charAt(0) === '/') vod[key] = base + pic;
          else if (pic.indexOf('./') === 0) vod[key] = base + pic.substring(1);
          else vod[key] = base + '/' + pic;
        }
      });
    });
    return list;
  }

  // 统一首页接口
  function apiHome(site) {
    if (isCmsSite(site)) {
      return cmsFetch(site, { filter: 'true' }).then(function (data) {
        var d = cmsUnwrap(data);
        var classes = d.class || d.classes || d.types || d.category || d.type || d.cats || [];
        var list = fixCmsPics(site, d.list || []);
        // 分类为空时，再请求一次标准首页接口补分类
        if (!classes.length) {
          return cmsFetch(site, { ac: 'videolist' }).then(function (data2) {
            var d2 = cmsUnwrap(data2);
            var classes2 = d2.class || d2.classes || d2.types || d2.category || d2.type || d2.cats || [];
            var list2 = fixCmsPics(site, d2.list || []);
            return {
              class: classes2,
              filters: d2.filters || d.filters || {},
              list: list2.length ? list2 : list
            };
          }).catch(function () {
            return { class: classes, filters: d.filters || {}, list: list };
          });
        }
        return {
          class: classes,
          filters: d.filters || {},
          list: list
        };
      });
    }
    return ant.source.home(site.key);
  }

  // 统一分类接口
  function apiCategory(site, tid, page, ext) {
    if (isCmsSite(site)) {
      var params = { t: tid, ac: 'videolist', pg: page || 1 };
      if (ext && typeof ext === 'object') {
        Object.keys(ext).forEach(function (k) {
          if (k !== 't' && k !== 'ac' && k !== 'pg' && ext[k] !== undefined && ext[k] !== null && String(ext[k]) !== '') {
            params[k] = ext[k];
          }
        });
      }
      return cmsFetch(site, params).then(function (data) {
        var d = cmsUnwrap(data);
        return {
          page: d.page || 1,
          pagecount: d.pagecount || d.pageCount || 1,
          limit: d.limit || 0,
          total: d.total || (d.list || []).length,
          list: fixCmsPics(site, d.list || [])
        };
      });
    }
    return ant.source.category({ siteKey: site.key, tid: tid, page: page, ext: ext });
  }

  // 统一详情接口
  function apiDetail(site, id) {
    if (isCmsSite(site)) {
      return cmsFetch(site, { ac: 'detail', ids: id }).then(function (data) {
        var d = cmsUnwrap(data);
        var list = fixCmsPics(site, d.list || []);
        healthRecord(site, 'detail', !!list.length);
        return list[0] || d;
      }).catch(function (e) { healthRecord(site, 'detail', false); throw e; });
    }
    return ant.source.detail({ siteKey: site.key, id: id })
      .then(function (r) { healthRecord(site, 'detail', !!r); return r; })
      .catch(function (e) { healthRecord(site, 'detail', false); throw e; });
  }

  // 统一搜索接口
  function apiSearch(site, wd, page) {
    if (isCmsSite(site)) {
      return cmsFetch(site, { ac: 'detail', wd: wd, pg: page || 1 }).then(function (data) {
        var d = cmsUnwrap(data);
        healthRecord(site, 'search', !!(d.list && d.list.length));
        return {
          page: d.page || 1,
          pagecount: d.pagecount || d.pageCount || 1,
          limit: d.limit || 0,
          total: d.total || (d.list || []).length,
          list: fixCmsPics(site, d.list || [])
        };
      }).catch(function (e) { healthRecord(site, 'search', false); throw e; });
    }
    return ant.source.search({ siteKey: site.key, wd: wd, page: page })
      .then(function (r) { healthRecord(site, 'search', !!(r && r.list && r.list.length)); return r; })
      .catch(function (e) { healthRecord(site, 'search', false); throw e; });
  }

  // 统一播放接口
  function apiPlay(site, flag, id) {
    if (isCmsSite(site)) {
      // CMS源先尝试宿主采集源（Python爬虫脚本源需要通过ant.source.play解析真实地址）
      var rawKey = site._cmsKey || site.key.replace(/^cms_/, '');
      return ant.source.play({ siteKey: rawKey, flag: flag, id: id })
        .then(function (r) {
          healthRecord(site, 'play', true);
          // 宿主返回有效地址就用宿主的
          if (r && (r.url || r.parse === '1' || r.jx === '1')) return r;
          return { parse: 0, jx: 0, url: id, header: {}, flag: flag };
        })
        .catch(function () {
          // 宿主没有对应源或调用失败，回退到CMS直接地址
          healthRecord(site, 'play', true);
          return { parse: 0, jx: 0, url: id, header: {}, flag: flag };
        });
    }
    return ant.source.play({ siteKey: site.key, flag: flag, id: id })
      .then(function (r) { healthRecord(site, 'play', true); return r; })
      .catch(function (e) { healthRecord(site, 'play', false); throw e; });
  }

  /* ========== 站点健康度（WebHomeTV 移植） ========== */
  var HEALTH_KEY = 'emby-site-health';
  var healthCache = null;

  function healthLoad() {
    if (healthCache) return Promise.resolve(healthCache);
    return ant.storage.getJSON(HEALTH_KEY, {}).then(function (d) {
      healthCache = d || {};
      return healthCache;
    });
  }

  function healthSave() {
    return ant.storage.setJSON(HEALTH_KEY, healthCache || {}).catch(function () {});
  }

  function healthRecord(site, type, success) {
    if (!site || !site.key) return;
    var key = site.key;
    return healthLoad().then(function () {
      if (!healthCache[key]) healthCache[key] = { search: { t: 0, s: 0 }, detail: { t: 0, s: 0 }, play: { t: 0, s: 0 } };
      if (!healthCache[key][type]) healthCache[key][type] = { t: 0, s: 0 };
      healthCache[key][type].t++;
      if (success) healthCache[key][type].s++;
      healthSave();
    });
  }

  function healthScore(site) {
    if (!site || !site.key || !healthCache) return 50;
    var h = healthCache[site.key];
    if (!h) return 50;
    var sr = h.search.t ? h.search.s / h.search.t : 0.5;
    var dr = h.detail.t ? h.detail.s / h.detail.t : 0.5;
    var pr = h.play.t ? h.play.s / h.play.t : 0.5;
    // 样本太少时降低置信度，保底50分
    var total = h.search.t + h.detail.t + h.play.t;
    var confidence = Math.min(1, total / 10);
    var raw = sr * 0.3 + dr * 0.3 + pr * 0.4;
    return Math.round((raw * confidence + 0.5 * (1 - confidence)) * 100);
  }

  function healthSortSites(sites) {
    return healthLoad().then(function () {
      return sites.slice().sort(function (a, b) {
        return healthScore(b) - healthScore(a);
      });
    });
  }

  function switchSite() {
    if (App.sites.length < 2) {
      toast('只有一个可用采集源');
      return;
    }
    openSitePanel();
  }

  function openSitePanel() {
    var tree = buildSiteTree(App.sites);
    var hasGroups = tree.length > 1 || (tree.length === 1 && tree[0].name !== '未分组');
    var currentKey = App.site ? App.site.key : '';

    var mask = document.createElement('div');
    mask.className = 'site-mask';
    mask.innerHTML =
      '<div class="site-panel" data-focus>' +
        '<div class="site-panel-head">' +
          '<h3>切换采集源</h3>' +
          '<div style="display:flex;align-items:center;gap:8px">' +
            '<button data-focus class="site-health-toggle" id="sp-health-sort" style="background:transparent;border:1px solid #555;color:#aaa;padding:4px 10px;border-radius:12px;font-size:11px;cursor:pointer">健康排序</button>' +
            '<button data-focus class="site-panel-close" id="sp-close">✕</button>' +
          '</div>' +
        '</div>' +
        '<div class="site-panel-search">' +
          '<input id="sp-search" type="text" placeholder="搜索源名称…" autocomplete="off" />' +
        '</div>' +
        '<div class="site-panel-body">' +
          (hasGroups ? '<div class="site-groups" id="sp-groups"></div>' : '') +
          '<div class="site-list-col" id="sp-sites"></div>' +
        '</div>' +
        '<div class="site-panel-foot"><span id="sp-count">' + App.sites.length + ' 个源</span></div>' +
      '</div>';
    document.body.appendChild(mask);

    var groupsBox = mask.querySelector('#sp-groups');
    var sitesBox = mask.querySelector('#sp-sites');
    var searchInput = mask.querySelector('#sp-search');
    var activeGroup = hasGroups ? tree[0].name : '';
    var keyword = '';

    function filteredSites() {
      var list = [];
      tree.forEach(function (g) {
        if (hasGroups && g.name !== activeGroup) return;
        g.sites.forEach(function (s) { list.push(s); });
      });
      if (keyword) {
        var kw = keyword.toLowerCase();
        list = list.filter(function (s) {
          return String(s.name || '').toLowerCase().indexOf(kw) >= 0 ||
                 String(s.key || '').toLowerCase().indexOf(kw) >= 0;
        });
      }
      return list;
    }

    function paintGroups() {
      if (!groupsBox) return;
      groupsBox.innerHTML = tree.map(function (g) {
        return '<button data-focus class="site-group ' + (g.name === activeGroup ? 'on' : '') +
          '" data-group="' + esc(g.name) + '">' + esc(g.name) +
          '<span class="site-group-count">' + g.sites.length + '</span></button>';
      }).join('');
      groupsBox.querySelectorAll('.site-group').forEach(function (node) {
        node.addEventListener('click', function () {
          activeGroup = node.dataset.group;
          paintGroups();
          paintSites();
        });
      });
    }

    var healthSortEnabled = false;

    function paintSites() {
      var list = filteredSites();
      if (healthSortEnabled) {
        list = list.slice().sort(function (a, b) { return healthScore(b) - healthScore(a); });
      }
      if (!list.length) {
        sitesBox.innerHTML = '<div class="site-empty">没有匹配的源</div>';
        return;
      }
      sitesBox.innerHTML = list.map(function (s) {
        var isCurrent = s.key === currentKey;
        var score = healthScore(s);
        var healthColor = score >= 70 ? '#4caf50' : score >= 40 ? '#ff9800' : '#f44336';
        var typeTag = isCmsSite(s)
          ? '<span class="site-type-tag cms">CMS</span>'
          : (s.sourceType === 'python' || (s.type && String(s.type).toLowerCase().indexOf('py') >= 0)
            ? '<span class="site-type-tag python">PY</span>'
            : '<span class="site-type-tag host">源</span>');
        return '<button data-focus class="site-item ' + (isCurrent ? 'current' : '') +
          '" data-key="' + esc(s.key) + '">' +
          '<div class="site-item-name">' + typeTag + esc(s.name || s.key) +
          '<span class="site-health" style="color:' + healthColor + '">健康' + score + '</span></div>' +
          '<div class="site-item-key">key: ' + esc(s.key) + '</div>' +
          (isCurrent ? '<span class="site-item-badge">当前</span>' : '') +
          '</button>';
      }).join('');
      sitesBox.querySelectorAll('.site-item').forEach(function (node) {
        node.addEventListener('click', function () {
          var key = node.dataset.key;
          if (key === currentKey) { closePanel(); return; }
          var next = App.sites.find(function (s) { return s.key === key; });
          if (!next) return;
          ant.storage.set('site', key).then(function () {
            closePanel();
            location.reload();
          }).catch(function (e) { toast('切换失败：' + errText(e)); });
        });
      });
    }

    function closePanel() {
      if (mask.parentNode) mask.parentNode.removeChild(mask);
    }

    mask.addEventListener('click', function (e) {
      if (e.target === mask) closePanel();
    });
    mask.querySelector('#sp-close').addEventListener('click', closePanel);
    searchInput.addEventListener('input', function () {
      keyword = searchInput.value.trim();
      paintSites();
    });

    var healthSortBtn = mask.querySelector('#sp-health-sort');
    healthSortBtn.addEventListener('click', function () {
      healthSortEnabled = !healthSortEnabled;
      healthSortBtn.style.background = healthSortEnabled ? 'var(--accent)' : 'transparent';
      healthSortBtn.style.color = healthSortEnabled ? '#fff' : '#aaa';
      healthSortBtn.style.borderColor = healthSortEnabled ? 'var(--accent)' : '#555';
      paintSites();
    });

    if (hasGroups) {
      // 默认选中包含当前源的分组
      var currentGroup = '';
      tree.forEach(function (g) {
        if (g.sites.some(function (s) { return s.key === currentKey; })) currentGroup = g.name;
      });
      if (currentGroup) activeGroup = currentGroup;
      paintGroups();
    }
    paintSites();
    setTimeout(function () { searchInput.focus(); }, 50);
  }

  /* ---------------- 启动 ---------------- */

  function stateHtml(icon, title, detail, actionHtml) {
    return '<div class="state"><div class="ico">' + icon + '</div><h3>' +
      esc(title) + '</h3><p>' + detail + '</p>' + (actionHtml || '') + '</div>';
  }

  /**
   * 解析站点、渲染顶栏、装上遥控焦点。
   * 返回 false 表示环境不满足，调用方应停止后续渲染。
   */
  function boot(options) {
    var opts = options || {};
    var main = document.getElementById('app-main');

    if (typeof window.ant === 'undefined') {
      if (main) {
        main.innerHTML = stateHtml(
          '🧩', '需要在宿主里运行',
          '这个页面依赖宿主注入的 <code>window.ant</code>。<br/>' +
          '在浏览器里开发请先引入 ant-mock.js。'
        );
      }
      return Promise.resolve(false);
    }

    renderHeader(opts.active);
    initTvFocus();

    // 双源加载：宿主采集源 + CMS配置源
    return Promise.all([
      ant.source.list().catch(function () { return []; }),
      t4ReadConfig().catch(function () { return { sites: [], selectedKey: '' }; })
    ]).then(function (results) {
      var hostSites = (results[0] || []).map(function (s) {
        s.sourceType = 'host';
        s.group = '采集源';
        return s;
      });
      var cmsSites = (results[1].sites || []).map(function (s) {
        return {
          key: 'cms_' + s.key,
          name: s.name,
          sourceType: 'cms',
          cmsUrl: s.url,
          group: s.group || '未分组',
          _cmsKey: s.key
        };
      });
      App.sites = hostSites.concat(cmsSites);

      if (!App.sites.length) {
        paintSiteChip();
        if (main) {
          main.innerHTML = stateHtml(
            '📡', '还没有可用的源',
            '可以在「设置」里添加 CMS 接口，或在宿主影视模块里配置采集源。'
          );
        }
        return false;
      }
      return ant.storage.get('site').then(function (saved) {
        App.site = null;
        for (var i = 0; i < App.sites.length; i++) {
          if (App.sites[i].key === saved) { App.site = App.sites[i]; break; }
        }
        if (!App.site) App.site = App.sites[0];
        paintSiteChip();
        return true;
      });
    }).catch(function (e) {
      if (main) {
        main.innerHTML = stateHtml('⚠️', '源读取失败', esc(errText(e)));
      }
      return false;
    });
  }

  /* ---------------- 卡片 ---------------- */

  function posterHtml(vod) {
    var pic = vod.vod_pic || '';
    var name = vod.vod_name || '';
    var inner = pic
      ? '<img loading="lazy" src="' + esc(pic) + '" alt="" ' +
        'onerror="this.parentNode.innerHTML=\'<div class=&quot;ph&quot;>' +
        esc(name.slice(0, 1)) + '</div>\'"/>'
      : '<div class="ph">' + esc(name.slice(0, 1)) + '</div>';
    var badge = vod.vod_remarks
      ? '<div class="badge">' + esc(vod.vod_remarks) + '</div>' : '';
    var bar = vod.__progress
      ? '<div class="progress"><i style="width:' + vod.__progress + '%"></i></div>' : '';
    return '<div class="poster">' + inner + badge + bar + '</div>';
  }

  function cardHtml(vod, index) {
    var sub = vod.vod_year || vod.vod_type || vod.vod_area || '';
    return '<button data-focus class="card" data-index="' + index + '">' +
      posterHtml(vod) +
      '<div class="card-name">' + esc(vod.vod_name || '未命名') + '</div>' +
      (sub ? '<div class="card-sub">' + esc(sub) + '</div>' : '') +
      '</button>';
  }

  /** 渲染一批卡片并绑定点击 → 详情页。 */
  function renderCards(container, list, options) {
    var opts = options || {};
    if (!container) return;
    if (!list || !list.length) {
      container.innerHTML =
        '<div class="hint" style="padding:18px 0">' +
        esc(opts.empty || '没有内容') + '</div>';
      return;
    }
    container.innerHTML = list.map(cardHtml).join('');
    container.querySelectorAll('.card').forEach(function (node) {
      node.addEventListener('click', function () {
        openDetail(list[Number(node.dataset.index)]);
      });
    });
  }

  /** wrapClass 传 null 时只返回骨架单元，方便塞进已有的容器。 */
  function skeleton(count, wrapClass) {
    var one = '<div><div class="sk sk-poster"></div>' +
      '<div class="sk sk-line" style="width:82%"></div>' +
      '<div class="sk sk-line" style="width:52%"></div></div>';
    var cells = '';
    for (var i = 0; i < count; i++) cells += one;
    if (wrapClass === null) return cells;
    return '<div class="' + (wrapClass || 'rail') + '">' + cells + '</div>';
  }

  /* ---------------- 页面跳转 ---------------- */

  /**
   * vod_id 在爬虫源里可能是很长的 JSON 串，放 URL 不可靠，
   * 所以摘要走 ant.storage 传递，URL 只带 id 兜住刷新场景。
   */
  function openDetail(vod) {
    if (!vod) return;
    ant.storage
      .setJSON('nav.detail', {
        siteKey: App.site ? App.site.key : '',
        vod: vod
      })
      .then(function () {
        return ant.navigateTo(
          'detail.html?id=' + encodeURIComponent(vod.vod_id || '')
        );
      })
      .catch(function (e) { toast('打开失败：' + errText(e)); });
  }

  function openLibrary(typeId, typeName) {
    ant.navigateTo(
      'library.html?tid=' + encodeURIComponent(typeId) +
      '&name=' + encodeURIComponent(typeName || '')
    );
  }

  /* ---------------- 观看历史 ---------------- */

  var HISTORY_MAX = 20;

  function getHistory() {
    return ant.storage.getJSON('history', []).then(function (list) {
      return Array.isArray(list) ? list : [];
    });
  }

  function pushHistory(siteKey, vod) {
    if (!vod || !vod.vod_id) return Promise.resolve();
    return getHistory().then(function (list) {
      var kept = list.filter(function (item) {
        return !(item.siteKey === siteKey && item.vodId === String(vod.vod_id));
      });
      kept.unshift({
        siteKey: siteKey,
        vodId: String(vod.vod_id),
        vod_id: vod.vod_id,
        vod_name: vod.vod_name,
        vod_pic: vod.vod_pic,
        vod_remarks: vod.vod_remarks,
        vod_year: vod.vod_year,
        at: Date.now()
      });
      return ant.storage.setJSON('history', kept.slice(0, HISTORY_MAX));
    });
  }

  function epKey(siteKey, vodId) {
    return 'ep:' + siteKey + ':' + vodId;
  }

  function getLastEp(siteKey, vodId) {
    return ant.storage.getJSON(epKey(siteKey, vodId), null);
  }

  function setLastEp(siteKey, vodId, record) {
    return ant.storage.setJSON(epKey(siteKey, vodId), record);
  }

  /* ========== 播放进度续播（WebHomeTV 移植） ========== */
  function progressKey(siteKey, vodId) {
    return 'prog:' + siteKey + ':' + vodId;
  }

  function getPlayProgress(siteKey, vodId) {
    return ant.storage.getJSON(progressKey(siteKey, vodId), null);
  }

  function setPlayProgress(siteKey, vodId, data) {
    return ant.storage.setJSON(progressKey(siteKey, vodId), data);
  }

  function updatePlayProgress(siteKey, vodId, lineName, epName, epId, position, duration) {
    return getPlayProgress(siteKey, vodId).then(function (old) {
      var data = old || {};
      // 只保存同一集的进度，不同集覆盖
      if (data.epId !== epId) {
        data = { line: lineName, name: epName, epId: epId, position: position, duration: duration, updatedAt: Date.now() };
      } else {
        data.position = position;
        data.duration = duration;
        data.updatedAt = Date.now();
      }
      return setPlayProgress(siteKey, vodId, data);
    });
  }

  /* ---------------- 线路与选集 ---------------- */

  /**
   * 把 vod_play_from / vod_play_url 解析成线路数组。
   * 宿主返回时这两个字段已经是数组（按 $$$ 切好），线内格式是
   * `名称$地址#名称$地址`。
   */
  function parseLines(vod) {
    // 兼容字符串（按$$$分割）和数组两种格式
    var rawFrom = vod && vod.vod_play_from ? vod.vod_play_from : '';
    var rawUrl = vod && vod.vod_play_url ? vod.vod_play_url : '';
    var froms = Array.isArray(rawFrom) ? rawFrom : String(rawFrom).split('$$$');
    var urls = Array.isArray(rawUrl) ? rawUrl : String(rawUrl).split('$$$');
    var lines = [];

    for (var i = 0; i < Math.max(froms.length, urls.length); i++) {
      var raw = String(urls[i] == null ? '' : urls[i]);
      if (!raw) continue;
      var episodes = raw.split('#').map(function (chunk) {
        var text = String(chunk).trim();
        if (!text) return null;
        var at = text.indexOf('$');
        if (at < 0) return { name: text, id: text };
        return {
          name: text.slice(0, at).trim() || '播放',
          id: text.slice(at + 1).trim()
        };
      }).filter(Boolean);

      if (!episodes.length) continue;
      var name = String(froms[i] == null ? '' : froms[i]).trim();
      lines.push({ name: name || '线路' + (i + 1), episodes: episodes });
    }
    return lines;
  }

  /** 从 source.play 的返回里挑出一个可播地址。 */
  function pickUrl(info) {
    if (!info) return '';
    var url = info.url;
    if (typeof url === 'string') return url.trim();
    if (Array.isArray(url)) {
      for (var i = 0; i < url.length; i++) {
        var item = url[i];
        if (typeof item === 'string' && /^https?:/i.test(item)) return item;
      }
    }
    return '';
  }

  /**
   * 解析并播放一集。
   *
   * 统一走 source.play：CMS 源会原样回显地址，爬虫源会去解析，
   * 两种情况调用方都不用区分。
   */
  function playEpisode(site, vod, line, episode) {
    var title = (vod.vod_name || '播放') + ' · ' + episode.name;
    var siteKey = site && site.key ? site.key : String(site || '');

    return apiPlay(site, line.name, episode.id)
      .then(function (info) {
        var url = pickUrl(info);
        var needSniff =
          info && (String(info.parse) === '1' || String(info.jx) === '1');

        if (needSniff) {
          var e = new Error('这条线路需要宿主内置解析，小程序里放不了，换一条线路试试');
          e.code = 'NEED_SNIFF';
          throw e;
        }
        if (!url && /^https?:/i.test(episode.id)) url = episode.id;
        if (!url) {
          var e2 = new Error('没有拿到可播放地址');
          e2.code = 'NO_URL';
          throw e2;
        }
        if (info && info.header && Object.keys(info.header).length) {
          ant.log('该地址带请求头，当前 player.open 不支持下发，可能取流失败');
        }
        return ant.player.open({ url: url, title: title });
      })
      .then(function () {
        return setLastEp(siteKey, String(vod.vod_id), {
          line: line.name,
          name: episode.name,
          id: episode.id,
          at: Date.now()
        });
      })
      .then(function () { return ant.ui.hideLoading(); })
      .catch(function (e) {
        return ant.ui.hideLoading().then(function () {
          toast(e && e.code === 'NEED_SNIFF' ? e.message : '播放失败：' + errText(e));
          throw e;
        });
      });
  }
  /* ---------------- 遥控器焦点 ---------------- */

  var focusEl = null;

  function focusCandidates() {
    return Array.prototype.filter.call(
      document.querySelectorAll('[data-focus]'),
      function (node) {
        var r = node.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      }
    );
  }

  function centerOf(node) {
    var r = node.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }

  function setFocus(node) {
    if (!node) return;
    if (focusEl) focusEl.classList.remove('tv-focus');
    focusEl = node;
    node.classList.add('tv-focus');
    try { node.focus({ preventScroll: true }); } catch (e) { node.focus(); }
    node.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  /**
   * 按几何位置找同方向最近的可聚焦元素。
   * 比按 DOM 顺序走靠谱得多——横向 rail 和网格混排时，DOM 顺序和视觉顺序常常不一致。
   */
  function moveFocus(direction) {
    var items = focusCandidates();
    if (!items.length) return;
    if (!focusEl || items.indexOf(focusEl) < 0) {
      setFocus(items[0]);
      return;
    }

    var from = centerOf(focusEl);
    var best = null;
    var bestScore = Infinity;

    items.forEach(function (node) {
      if (node === focusEl) return;
      var to = centerOf(node);
      var dx = to.x - from.x;
      var dy = to.y - from.y;
      var main;
      var cross;

      if (direction === 'ArrowLeft') { main = -dx; cross = Math.abs(dy); }
      else if (direction === 'ArrowRight') { main = dx; cross = Math.abs(dy); }
      else if (direction === 'ArrowUp') { main = -dy; cross = Math.abs(dx); }
      else { main = dy; cross = Math.abs(dx); }

      if (main <= 2) return;                 // 不在这个方向上
      var score = main + cross * 2.2;        // 偏向同一排 / 同一列
      if (score < bestScore) { bestScore = score; best = node; }
    });

    if (best) setFocus(best);
  }

  function initTvFocus() {
    if (!window.ant || !ant.tv || initTvFocus.done) return;
    initTvFocus.done = true;

    ant.tv.onKey(function (event) {
      var key = event && event.key;
      if (key === 'Enter') {
        if (focusEl) focusEl.click();
        else moveFocus('ArrowDown');
        return;
      }
      if (key && key.indexOf('Arrow') === 0) moveFocus(key);
    });

    // 鼠标/触摸点过的元素同步成当前焦点，避免遥控接管后焦点跳回开头
    document.addEventListener('click', function (event) {
      var node = event.target && event.target.closest
        ? event.target.closest('[data-focus]')
        : null;
      if (node) setFocus(node);
    }, true);
  }

  /* ================= T4 服务（CMS 转 T4，合入影视库） ================= */

  var T4_KEY = 'emby-t4-config';
  var T4_APP_ID = 'com.leospring.emby';
  var T4_INTERNAL_BASE = 'miniapp://' + T4_APP_ID;

  // 内置默认 CMS 站点（来自采集站配置，去重后 78 个）
  var DEFAULT_T4_SITES = [
    { key: "dyttzyapi", name: "TV-电影天堂资源", url: "http://caiji.dyttzyapi.com/api.php/provide/vod" },
    { key: "lziapi", name: "TV-量子资源", url: "https://cj.lziapi.com/api.php/provide/vod" },
    { key: "1080zyku", name: "TV-1080资源", url: "https://api.1080zyku.com/inc/api_mac10.php" },
    { key: "155api", name: "AV-155资源", url: "https://155api.com/api.php/provide/vod" },
    { key: "360zy", name: "TV-360资源", url: "https://360zy.com/api.php/provide/vod" },
    { key: "tyyszy", name: "TV-天涯资源", url: "https://tyyszy.com/api.php/provide/vod" },
    { key: "bfzyapi", name: "TV-暴风资源", url: "https://bfzyapi.com/api.php/provide/vod" },
    { key: "sdzyapi", name: "TV-索尼-闪电资源", url: "https://xsd.sdzyapi.com/api.php/provide/vod" },
    { key: "suoniapi", name: "TV-索尼资源", url: "https://suoniapi.com/api.php/provide/vod" },
    { key: "hongniuzy2", name: "TV-红牛资源", url: "https://www.hongniuzy2.com/api.php/provide/vod" },
    { key: "maotaizy", name: "TV-茅台资源", url: "https://caiji.maotaizy.cc/api.php/provide/vod" },
    { key: "huyaapi", name: "TV-虎牙资源", url: "https://www.huyaapi.com/api.php/provide/vod" },
    { key: "dbzy", name: "TV-豆瓣资源", url: "https://caiji.dbzy.tv/api.php/provide/vod" },
    { key: "dbzy_2", name: "TV-豆瓣资源2", url: "https://dbzy.tv/api.php/provide/vod" },
    { key: "dbzy5", name: "TV-豆瓣资源3", url: "https://caiji.dbzy5.com/api.php/provide/vod/from/dbm3u8/at/josn" },
    { key: "hhzyapi", name: "TV-豪华资源", url: "https://hhzyapi.com/api.php/provide/vod" },
    { key: "ckzy", name: "TV-CK资源", url: "https://ckzy.me/api.php/provide/vod" },
    { key: "ukuapi", name: "TV-U酷资源", url: "https://api.ukuapi.com/api.php/provide/vod" },
    { key: "ukuapi88", name: "TV-U酷资源2", url: "https://api.ukuapi88.com/api.php/provide/vod" },
    { key: "ikunzyapi", name: "TV-ikun资源", url: "https://ikunzyapi.com/api.php/provide/vod" },
    { key: "wujinapi", name: "TV-wujinapi无尽", url: "https://api.wujinapi.cc/api.php/provide/vod" },
    { key: "yayazy", name: "TV-丫丫点播", url: "https://cj.yayazy.net/api.php/provide/vod" },
    { key: "guangsuapi", name: "TV-光速资源", url: "https://api.guangsuapi.com/api.php/provide/vod" },
    { key: "wolongzyw", name: "TV-卧龙点播", url: "https://collect.wolongzyw.com/api.php/provide/vod" },
    { key: "wolongzy", name: "TV-卧龙资源", url: "https://collect.wolongzy.cc/api.php/provide/vod" },
    { key: "wolongzyw_2", name: "TV-卧龙资源2", url: "https://wolongzyw.com/api.php/provide/vod" },
    { key: "xinlangapi", name: "TV-新浪点播", url: "https://api.xinlangapi.com/xinlangapi.php/provide/vod" },
    { key: "wujinapi_2", name: "TV-无尽资源", url: "https://api.wujinapi.com/api.php/provide/vod" },
    { key: "wujinapi_3", name: "TV-无尽资源2", url: "https://api.wujinapi.me/api.php/provide/vod" },
    { key: "wujinapi_4", name: "TV-无尽资源3", url: "https://api.wujinapi.net/api.php/provide/vod" },
    { key: "wwzy", name: "TV-旺旺短剧", url: "https://wwzy.tv/api.php/provide/vod" },
    { key: "wwzy_2", name: "TV-旺旺资源", url: "https://api.wwzy.tv/api.php/provide/vod" },
    { key: "zuidazy", name: "TV-最大点播", url: "http://zuidazy.me/api.php/provide/vod" },
    { key: "zuidapi", name: "TV-最大资源", url: "https://api.zuidapi.com/api.php/provide/vod" },
    { key: "apiyhzy", name: "TV-樱花资源", url: "https://m3u8.apiyhzy.com/api.php/provide/vod" },
    { key: "yparse", name: "TV-步步高资源", url: "https://api.yparse.com/api/json" },
    { key: "niuniuzy", name: "TV-牛牛点播", url: "https://api.niuniuzy.me/api.php/provide/vod" },
    { key: "gayapi", name: "AV-gay资源", url: "https://gayapi.com/api.php/provide/vod/at/json" },
    { key: "apibdzy", name: "TV-百度云资源", url: "https://api.apibdzy.com/api.php/provide/vod" },
    { key: "1080zyku_2", name: "TV-神马云", url: "https://api.1080zyku.com/inc/apijson.php/" },
    { key: "subocaiji", name: "TV-速博资源", url: "https://subocaiji.com/api.php/provide/vod" },
    { key: "jinyingzy", name: "TV-金鹰点播", url: "https://jinyingzy.com/api.php/provide/vod" },
    { key: "jyzyapi", name: "TV-金鹰资源", url: "https://jyzyapi.com/api.php/provide/vod" },
    { key: "sdzyapi_2", name: "TV-閃電资源", url: "https://sdzyapi.com/api.php/provide/vod" },
    { key: "ffzyapi", name: "TV-非凡资源", url: "https://cj.ffzyapi.com/api.php/provide/vod" },
    { key: "p2100", name: "TV-飘零资源", url: "https://p2100.net/api.php/provide/vod" },
    { key: "mozhuazy", name: "TV-魔爪资源", url: "https://mozhuazy.com/api.php/provide/vod" },
    { key: "moduapi", name: "TV-魔都动漫", url: "https://caiji.moduapi.cc/api.php/provide/vod" },
    { key: "mdzyapi", name: "TV-魔都资源", url: "https://www.mdzyapi.com/api.php/provide/vod" },
    { key: "91md", name: "AV-91麻豆", url: "https://91md.me/api.php/provide/vod" },
    { key: "lbapiby", name: "AV-AIvin", url: "http://lbapiby.com/api.php/provide/vod" },
    { key: "jkunzyapi", name: "AV-JKUN资源", url: "https://jkunzyapi.com/api.php/provide/vod" },
    { key: "souavzy", name: "AV-souav资源", url: "https://api.souavzy.vip/api.php/provide/vod" },
    { key: "lbapi9", name: "AV-乐播资源", url: "https://lbapi9.com/api.php/provide/vod" },
    { key: "aosikazy", name: "AV-奥斯卡资源", url: "https://aosikazy.com/api.php/provide/vod" },
    { key: "naixxzy", name: "AV-奶香香", url: "https://Naixxzy.com/api.php/provide/vod" },
    { key: "slapibf", name: "AV-森林资源", url: "https://slapibf.com/api.php/provide/vod" },
    { key: "xrbsp", name: "AV-淫水机资源", url: "https://www.xrbsp.com/api/json.php" },
    { key: "apiyutu", name: "AV-玉兔资源", url: "https://apiyutu.com/api.php/provide/vod" },
    { key: "fhapi9", name: "AV-番号资源", url: "http://fhapi9.com/api.php/provide/vod" },
    { key: "kxgav", name: "AV-白嫖资源", url: "https://www.kxgav.com/api/json.php" },
    { key: "jingpinx", name: "AV-精品资源", url: "https://www.jingpinx.com/api.php/provide/vod" },
    { key: "msnii", name: "AV-美少女资源", url: "https://www.msnii.com/api/json.php" },
    { key: "apilsbzy1", name: "AV-老色逼资源", url: "https://apilsbzy1.com/api.php/provide/vod" },
    { key: "sexnguon", name: "AV-色南国", url: "https://api.sexnguon.com/api.php/provide/vod" },
    { key: "maozyapi", name: "AV-色猫资源", url: "https://api.maozyapi.com/inc/apijson_vod.php" },
    { key: "apilj", name: "AV-辣椒资源", url: "https://apilj.com/api.php/provide/vod" },
    { key: "gdlsp", name: "AV-香奶儿资源", url: "https://www.gdlsp.com/api/json.php" },
    { key: "shayuapi", name: "AV-鲨鱼资源", url: "https://shayuapi.com/api.php/provide/vod" },
    { key: "pgxdy", name: "AV-黄AV资源", url: "https://www.pgxdy.com/api/json.php" },
    { key: "jszyapi", name: "TV-极速资源", url: "https://jszyapi.com/api.php/provide/vod" },
    { key: "xingba111", name: "杏吧资源", url: "https://xingba111.com/api.php/provide/vod" },
    { key: "hongniuzy3", name: "TV-红牛资源", url: "https://www.hongniuzy3.com/api.php/provide/vod" },
    { key: "seacms", name: "TV-海洋资源", url: "http://www.seacms.org/api.php/provide/vod" },
    { key: "hsckzy888", name: "黄色资源啊啊", url: "https://hsckzy888.com/api.php/provide/vod" },
    { key: "xiaojizy", name: "小鸡资源", url: "https://api.xiaojizy.live/provide/vod" },
    { key: "apilj_2", name: "辣椒资源黄黄", url: "https://apilj.com/api.php/provide" },
    { key: "xxibaozyw", name: "细胞采集黄色", url: "https://www.xxibaozyw.com/api.php/provide/vod" }
  ];

  function t4NormalizeConfig(value) {
    if (value && Array.isArray(value.sites)) {
      var seen = {};
      var sites = value.sites.map(function (site) {
        return {
          key: String(site.key || '').trim(),
          name: String(site.name || 'CMS 影视源').trim() || 'CMS 影视源',
          url: String(site.url || '').trim()
        };
      }).filter(function (site) {
        if (!site.key || !site.url || seen[site.key]) return false;
        seen[site.key] = true;
        return true;
      });
      var selected = String(value.selectedKey || '').trim();
      if (!sites.some(function (s) { return s.key === selected; })) selected = sites[0] ? sites[0].key : '';
      return { sites: sites, selectedKey: selected };
    }
    return { sites: [], selectedKey: '' };
  }

  function t4ReadConfig() {
    return ant.storage.getJSON(T4_KEY, null).then(function (stored) {
      var config = t4NormalizeConfig(stored);
      // 用户没有配置任何站点时，自动加载内置默认站点
      if (!config.sites.length && DEFAULT_T4_SITES.length) {
        config.sites = DEFAULT_T4_SITES.map(function (s) {
          return { key: s.key, name: s.name, url: s.url };
        });
        config.selectedKey = config.sites[0] ? config.sites[0].key : '';
      }
      return config;
    });
  }

  function t4SaveConfig(config) {
    return ant.storage.setJSON(T4_KEY, config);
  }

  function t4CleanKey(raw) {
    var value = String(raw || '').trim();
    if (!/^[a-zA-Z0-9_-]{1,40}$/.test(value)) throw new Error('key 只能包含字母、数字、下划线和短横线，长度 1-40');
    return value;
  }

  function t4CleanUrl(raw) {
    var value = String(raw || '').trim();
    if (!value) throw new Error('请填写 CMS JSON 接口');
    var parsed;
    try { parsed = new URL(value); } catch (e) { throw new Error('接口地址不是合法 URL'); }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') throw new Error('接口只支持 http 或 https');
    parsed.hash = '';
    return parsed.toString();
  }

  function t4ExtractUrls(text) {
    var raw = String(text || '');
    var matches = raw.match(/https?:\/\/[^\s<>"'`\]\)\}]+/gi) || [];
    var seen = {};
    var result = [];
    matches.forEach(function (u) {
      var trimmed = u.replace(/[.,;:!?，。；：！？、]+$/, '');
      if (!seen[trimmed]) { seen[trimmed] = true; result.push(trimmed); }
    });
    return result;
  }

  // 智能解析粘贴文本：支持 JSON 配置（api_site 数组，含 name/api）和纯 URL 列表
  function t4ParseImportText(text) {
    var raw = String(text || '').trim();
    if (!raw) return { items: [], mode: 'empty' };

    // 尝试解析为 JSON
    try {
      var obj = JSON.parse(raw);
      // 标准格式：{ api_site: [{ name, api, ... }, ...] }
      var list = null;
      if (Array.isArray(obj)) list = obj;
      else if (Array.isArray(obj.api_site)) list = obj.api_site;
      else if (Array.isArray(obj.sites)) list = obj.sites;
      else if (Array.isArray(obj.list)) list = obj.list;
      else if (obj.data && Array.isArray(obj.data.api_site)) list = obj.data.api_site;
      else if (obj.data && Array.isArray(obj.data.sites)) list = obj.data.sites;

      if (list && list.length) {
        var items = [];
        list.forEach(function (entry) {
          if (!entry || typeof entry !== 'object') return;
          var url = String(entry.api || entry.url || entry.api_url || entry.interface || '').trim();
          if (!url) return;
          // 清理 URL
          try {
            var parsed = new URL(url);
            parsed.hash = '';
            url = parsed.toString();
          } catch (e) { return; }
          var name = String(entry.name || entry.title || entry.site_name || '').trim();
          items.push({ name: name, url: url });
        });
        if (items.length) return { items: items, mode: 'json' };
      }
    } catch (e) { /* 不是 JSON，回退到 URL 提取 */ }

    // 回退：纯 URL 提取
    var urls = t4ExtractUrls(raw);
    var fallbackItems = urls.map(function (u) { return { name: '', url: u }; });
    return { items: fallbackItems, mode: 'url' };
  }

  function t4DeriveKey(url, existingKeys) {
    var parsed;
    try { parsed = new URL(url); } catch (e) { return ''; }
    var host = parsed.hostname.replace(/^www\./, '').toLowerCase();
    var parts = host.split('.');
    var main = parts.length >= 2 ? parts[parts.length - 2] : host;
    var key = main.replace(/[^a-zA-Z0-9_-]/g, '_').replace(/^_+|_+$/g, '');
    if (!key) key = 'site';
    if (key.length > 36) key = key.slice(0, 36);
    var candidate = key;
    var counter = 2;
    while (existingKeys[candidate]) { candidate = key + '_' + counter; counter++; if (counter > 999) break; }
    return candidate;
  }

  function t4CmsUrl(config, params) {
    var url = new URL(config.url);
    Object.keys(params || {}).forEach(function (key) {
      var value = params[key];
      if (value !== undefined && value !== null && String(value) !== '') {
        url.searchParams.set(key, String(value));
      }
    });
    return url.toString();
  }

  function t4DecodeExt(value) {
    if (!value) return {};
    if (typeof value === 'object') return value;
    try {
      var raw = decodeURIComponent(String(value));
      if (raw.charAt(0) === '{') return JSON.parse(raw);
    } catch (_) {}
    try {
      var text = atob(value.replace(/-/g, '+').replace(/_/g, '/'));
      var bytes = new Uint8Array(text.length);
      for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
      return JSON.parse(new TextDecoder('utf-8').decode(bytes));
    } catch (e) {
      try { return JSON.parse(decodeURIComponent(escape(atob(value)))); } catch (_) { return {}; }
    }
  }

  function t4CategoryParams(raw) {
    var params = { t: raw.t, ac: 'videolist', pg: raw.pg || 1 };
    var ext = t4DecodeExt(raw.ext);
    Object.keys(ext || {}).forEach(function (key) {
      if (key === 't' || key === 'ac' || key === 'pg') return;
      if (ext[key] !== undefined && ext[key] !== null && String(ext[key]) !== '') params[key] = ext[key];
    });
    return params;
  }

  function t4Unwrap(payload) {
    if (payload && payload.data && typeof payload.data === 'object' &&
        (payload.data.list || payload.data.class || payload.data.classes)) {
      return payload.data;
    }
    return payload || {};
  }

  function t4AsList(value) { return Array.isArray(value) ? value : []; }

  function t4FetchJson(config, params) {
    return ant.request({
      url: t4CmsUrl(config, params),
      timeout: 60000,
      headers: { Accept: 'application/json, text/plain, */*', 'User-Agent': 'okhttp/4.12.0' }
    }).then(function (response) {
      var statusCode = Number(response && response.statusCode || 0);
      var rawData = response && response.data;
      if (statusCode < 200 || statusCode >= 300) {
        var errorBody = typeof rawData === 'string' ? rawData : JSON.stringify(rawData || '');
        var httpError = new Error('CMS HTTP ' + statusCode + (errorBody ? ': ' + errorBody.slice(0, 160) : ''));
        httpError.code = 'CMS_HTTP_' + statusCode;
        throw httpError;
      }
      if (rawData && typeof rawData === 'object') return rawData;
      var body = String(rawData || '').replace(/^\uFEFF/, '').trim();
      try { return JSON.parse(body); }
      catch (error) {
        var candidate = body.replace(/^\s*<pre[^>]*>/i, '').replace(/<\/pre>\s*$/i, '').trim();
        var jsonp = candidate.match(/^[\w$]+\s*\((.*)\)\s*;?$/s);
        if (jsonp) candidate = jsonp[1].trim();
        try { return JSON.parse(candidate); }
        catch (_) {
          var parseError = new Error('CMS 返回的不是 JSON：' + (body.slice(0, 180) || '空响应'));
          parseError.code = 'CMS_INVALID_JSON';
          throw parseError;
        }
      }
    });
  }

  function t4JsonResponse(value, statusCode) {
    return { status: statusCode || 200, headers: { 'Content-Type': 'application/json; charset=utf-8' }, body: JSON.stringify(value) };
  }

  function t4ErrorResponse(code, message, statusCode) {
    return t4JsonResponse({ code: code, msg: message, data: null }, statusCode || 400);
  }

  function t4SiteKeyFromRequest(req) {
    var fromParams = String((req && req.params && req.params.site) || '').trim();
    if (fromParams) return fromParams;
    var matched = String((req && req.path) || '').match(/^\/(?:site|s)\/([^/?#]+)/);
    return matched ? decodeURIComponent(matched[1]) : '';
  }

  function t4BusinessPath(req) {
    var path = String((req && req.path) || '/').replace(/^\/(?:site|s)\/[^/?#]+/, '');
    return path || '/';
  }

  function t4Descriptor(sites, base) {
    return {
      sites: sites.map(function (site) {
        var api = base.indexOf('miniapp://') === 0
          ? base + '/site/' + encodeURIComponent(site.key)
          : base + '/site/' + encodeURIComponent(site.key);
        return { key: site.key, name: site.name, type: 4, api: api, searchable: 1, quickSearch: 1, filterable: 1 };
      })
    };
  }

  function t4HandleService(req) {
    return t4ReadConfig().then(function (config) {
      var path = t4BusinessPath(req);
      if (path === '/health' || path === '/api/health') {
        return t4JsonResponse({ code: 0, msg: 'ok', data: {
          appId: T4_APP_ID, configured: config.sites.length > 0,
          sites: config.sites.length, siteKeys: config.sites.map(function (s) { return s.key; })
        } });
      }
      if (path === '/config' || path === '/api/config' || path === '/api/v1/config') {
        return t4JsonResponse(t4Descriptor(config.sites, T4_INTERNAL_BASE));
      }
      if (!config.sites.length) return t4ErrorResponse('NOT_CONFIGURED', '请先在影视库设置里配置 CMS 接口', 503);
      var requestedKey = t4SiteKeyFromRequest(req);
      var site = requestedKey
        ? config.sites.find(function (s) { return s.key === requestedKey; })
        : config.sites.find(function (s) { return s.key === config.selectedKey; }) || config.sites[0];
      if (!site) return t4ErrorResponse('SITE_NOT_FOUND', '找不到 CMS 站点: ' + requestedKey, 404);

      var params = req.params || {};
      var ac = String(params.ac || '').toLowerCase();
      if (params.play !== undefined && String(params.play) !== '') {
        var value = String(params.play || '').trim();
        try { value = decodeURIComponent(value); } catch (_) {}
        return t4JsonResponse({ parse: 0, jx: 0, url: value, header: {}, flag: String(params.flag || '') });
      }
      if (params.wd !== undefined && String(params.wd) !== '') {
        return t4FetchJson(site, { ac: 'detail', wd: params.wd, pg: params.pg || 1 })
          .then(function (data) {
            var d = t4Unwrap(data);
            return t4JsonResponse({ code: d.code || 0, msg: d.msg || 'success', page: d.page || 1, pagecount: d.pagecount || 1, limit: d.limit || 0, total: d.total || t4AsList(d.list).length, list: t4AsList(d.list) });
          });
      }
      if (ac === 'detail' && params.ids !== undefined && String(params.ids) !== '') {
        return t4FetchJson(site, { ac: 'detail', ids: params.ids })
          .then(function (data) {
            var d = t4Unwrap(data);
            return t4JsonResponse({ code: d.code || 0, msg: d.msg || 'success', page: d.page || 1, pagecount: d.pagecount || 1, limit: d.limit || 0, total: d.total || t4AsList(d.list).length, list: t4AsList(d.list) });
          });
      }
      if (params.t !== undefined && String(params.t) !== '') {
        return t4FetchJson(site, t4CategoryParams(params))
          .then(function (data) {
            var d = t4Unwrap(data);
            return t4JsonResponse({ code: d.code || 0, msg: d.msg || 'success', page: d.page || 1, pagecount: d.pagecount || 1, limit: d.limit || 0, total: d.total || t4AsList(d.list).length, list: t4AsList(d.list) });
          });
      }
      return t4FetchJson(site, { filter: 'true' })
        .then(function (data) {
          var d = t4Unwrap(data);
          return t4JsonResponse({ code: d.code || 0, msg: d.msg || 'success', class: t4AsList(d.class || d.classes), filters: d.filters || {}, list: t4AsList(d.list), page: d.page || 1, pagecount: d.pagecount || 1, limit: d.limit || 0, total: d.total || t4AsList(d.list).length });
        });
    }).catch(function (error) {
      var message = (error && error.message) || String(error);
      return t4ErrorResponse(error && error.code ? error.code : 'UPSTREAM_FAILED', message, 502);
    });
  }

  // 启动 T4 后台服务（每个页面加载 lib.js 时都会执行，保证后台拉起时服务可用）
  if (typeof ant !== 'undefined' && ant.serve) {
    try { ant.serve(t4HandleService); } catch (e) { /* 重复注册时静默 */ }
  }

  /* ---------------- 导出 ---------------- */

  window.EmbyUI = {
    esc: esc,
    qs: qs,
    pool: pool,
    errText: errText,
    toast: toast,
    boot: boot,
    stateHtml: stateHtml,
    skeleton: skeleton,
    posterHtml: posterHtml,
    cardHtml: cardHtml,
    renderCards: renderCards,
    openDetail: openDetail,
    openLibrary: openLibrary,
    switchSite: switchSite,
    healthScore: healthScore,
    healthSortSites: healthSortSites,
    healthRecord: healthRecord,
    getHistory: getHistory,
    pushHistory: pushHistory,
    getLastEp: getLastEp,
    setLastEp: setLastEp,
    getPlayProgress: getPlayProgress,
    setPlayProgress: setPlayProgress,
    updatePlayProgress: updatePlayProgress,
    parseLines: parseLines,
    playEpisode: playEpisode,
    setFocus: setFocus,
    t4ReadConfig: t4ReadConfig,
    t4SaveConfig: t4SaveConfig,
    t4NormalizeConfig: t4NormalizeConfig,
    t4CleanKey: t4CleanKey,
    t4CleanUrl: t4CleanUrl,
    t4ExtractUrls: t4ExtractUrls,
    t4ParseImportText: t4ParseImportText,
    t4DeriveKey: t4DeriveKey,
    t4FetchJson: t4FetchJson,
    t4Descriptor: t4Descriptor,
    t4InternalBase: T4_INTERNAL_BASE,
    isCmsSite: isCmsSite,
    apiHome: apiHome,
    apiCategory: apiCategory,
    apiDetail: apiDetail,
    apiSearch: apiSearch,
    apiPlay: apiPlay
  };
})();
