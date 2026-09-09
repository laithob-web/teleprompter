import Foundation

/// The page a phone or tablet loads. Self-contained: no frameworks, no CDN, so
/// it works on a network with no internet access at all.
enum PrompterPage {

    static func html(token: String) -> String {
        #"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta name="theme-color" content="#ffffff">
        <title>Teleprompter</title>
        <style>
          :root {
            --bg: #ffffff; --fg: #111111; --dim: #8a8a8e;
            --accent: #0a7d88; --bar: rgba(255,255,255,.94); --line: rgba(0,0,0,.12);
            --size: 30px;
          }
          body.dark {
            --bg: #000000; --fg: #f2f2f7; --dim: #8e8e93;
            --accent: #5ac8d8; --bar: rgba(0,0,0,.94); --line: rgba(255,255,255,.16);
          }
          * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
          html, body { margin: 0; height: 100%; overscroll-behavior: none; }
          body {
            background: var(--bg); color: var(--fg);
            font: 500 var(--size)/1.42 -apple-system, BlinkMacSystemFont,
                  "Segoe UI", Roboto, system-ui, sans-serif;
            transition: background .2s, color .2s;
          }
          #bar {
            position: fixed; inset: 0 0 auto 0; z-index: 10;
            display: flex; gap: 6px; align-items: center;
            padding: max(8px, env(safe-area-inset-top)) 10px 8px;
            background: var(--bar); border-bottom: 1px solid var(--line);
            backdrop-filter: saturate(1.4) blur(12px);
            font-size: 15px; font-weight: 600;
          }
          #bar button {
            font: inherit; font-size: 14px; color: var(--fg);
            background: transparent; border: 1px solid var(--line);
            border-radius: 8px; padding: 7px 11px; min-width: 40px;
          }
          #bar button.on { background: var(--accent); border-color: var(--accent); color: #fff; }
          #status { flex: 1; font-size: 12px; font-weight: 500; color: var(--dim);
                    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          #script {
            padding: 96px 22px calc(60vh + env(safe-area-inset-bottom));
            white-space: pre-wrap; word-wrap: break-word;
          }
          .heading {
            display: block; font-size: .62em; font-weight: 600;
            color: var(--accent); letter-spacing: .01em; margin: .7em 0 .12em;
          }
          .cur { background: rgba(10,125,136,.16); border-radius: 4px; }
          body.dark .cur { background: rgba(90,200,216,.22); }
          #sections {
            position: fixed; inset: 0; z-index: 20; display: none;
            background: var(--bg); overflow-y: auto;
            padding: max(12px, env(safe-area-inset-top)) 0 40px;
          }
          #sections.show { display: block; }
          #sections div {
            padding: 15px 20px; font-size: 17px; font-weight: 500;
            border-bottom: 1px solid var(--line);
          }
          #sections .close { color: var(--accent); font-weight: 700; }
        </style>
        </head>
        <body>
          <div id="bar">
            <button id="follow" class="on">Follow</button>
            <button id="list">☰</button>
            <button id="smaller">A−</button>
            <button id="bigger">A+</button>
            <button id="theme">◐</button>
            <span id="status">connecting…</span>
          </div>
          <div id="script"></div>
          <div id="sections"></div>

        <script>
        const TOKEN = "\#(token)";
        const script = document.getElementById('script');
        const statusEl = document.getElementById('status');
        const followBtn = document.getElementById('follow');

        let sections = [], wordCount = 0;
        let following = true;
        let manualUntil = 0;      // touch input wins for a few seconds
        let programmatic = false; // distinguishes our scrolling from yours
        let targetY = null, currentY = window.scrollY, lastCur = null;

        const esc = s => s.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));

        async function load() {
          try {
            const res = await fetch('/script?t=' + TOKEN);
            const data = await res.json();
            render(data);
            statusEl.textContent = sections.length + ' sections';
          } catch (e) {
            statusEl.textContent = 'could not load script';
          }
        }

        function render(data) {
          const text = data.text;
          sections = data.sections || [];
          wordCount = (data.words || []).length;

          // Plain text between words, each word in its own span so the Mac's
          // word indices address elements here directly.
          let cursor = 0, html = '';
          (data.words || []).forEach(([loc, len], i) => {
            html += esc(text.slice(cursor, loc));
            html += '<span id="w' + i + '">' + esc(text.substr(loc, len)) + '</span>';
            cursor = loc + len;
          });
          html += esc(text.slice(cursor));
          script.innerHTML = html;

          const list = document.getElementById('sections');
          list.innerHTML = '<div class="close">✕  Close</div>' + sections.map((s, i) =>
            '<div data-i="' + i + '">' + esc(s.title || '(untitled)') + '</div>').join('');
        }

        // ---- position updates from the Mac ----
        function connect() {
          const source = new EventSource('/events?t=' + TOKEN);
          source.addEventListener('position', e => {
            const d = JSON.parse(e.data);
            highlight(d.word);
            if (following && Date.now() > manualUntil) scrollToWord(d.word);
            statusEl.textContent = (d.confident ? 'following' : 'drifting')
              + (d.section != null && sections[d.section]
                 ? ' · ' + (sections[d.section].title || '') : '');
          });
          source.addEventListener('reload', () => load());
          source.onopen = () => { if (statusEl.textContent === 'connecting…')
                                    statusEl.textContent = 'connected'; };
          source.onerror = () => {
            statusEl.textContent = 'reconnecting…';
            // EventSource retries on its own; nothing to do but wait.
          };
        }

        function highlight(n) {
          if (lastCur !== null) {
            const prev = document.getElementById('w' + lastCur);
            if (prev) prev.classList.remove('cur');
          }
          const el = document.getElementById('w' + n);
          if (el) el.classList.add('cur');
          lastCur = n;
        }

        function scrollToWord(n) {
          const el = document.getElementById('w' + n);
          if (!el) return;
          // Put the current word ~38% down the screen, matching the Mac.
          targetY = el.getBoundingClientRect().top + window.scrollY
                    - window.innerHeight * 0.38;
        }

        // Critically damped glide, so a jump does not whip the page.
        function tick() {
          if (targetY !== null) {
            const delta = targetY - window.scrollY;
            if (Math.abs(delta) < 1.5) {
              targetY = null;
            } else {
              programmatic = true;
              window.scrollTo(0, window.scrollY + delta * 0.18);
              requestAnimationFrame(() => { programmatic = false; });
            }
          }
          requestAnimationFrame(tick);
        }
        requestAnimationFrame(tick);

        // ---- manual scrolling wins ----
        function noteManual() { manualUntil = Date.now() + 4000; targetY = null; }
        window.addEventListener('touchstart', noteManual, { passive: true });
        window.addEventListener('touchmove', noteManual, { passive: true });
        window.addEventListener('wheel', noteManual, { passive: true });
        window.addEventListener('scroll', () => { if (!programmatic) noteManual(); },
                                { passive: true });

        // ---- controls ----
        followBtn.onclick = () => {
          following = !following;
          followBtn.classList.toggle('on', following);
          if (following) { manualUntil = 0; if (lastCur !== null) scrollToWord(lastCur); }
        };
        document.getElementById('bigger').onclick = () => setSize(2);
        document.getElementById('smaller').onclick = () => setSize(-2);
        function setSize(d) {
          const now = parseInt(getComputedStyle(document.documentElement)
                       .getPropertyValue('--size')) || 30;
          const next = Math.min(72, Math.max(14, now + d));
          document.documentElement.style.setProperty('--size', next + 'px');
          localStorage.setItem('size', next);
        }
        document.getElementById('theme').onclick = () => {
          document.body.classList.toggle('dark');
          localStorage.setItem('dark', document.body.classList.contains('dark') ? '1' : '0');
        };
        const list = document.getElementById('sections');
        document.getElementById('list').onclick = () => list.classList.add('show');
        list.onclick = e => {
          const i = e.target.dataset.i;
          if (i !== undefined && sections[i]) {
            list.classList.remove('show');
            manualUntil = Date.now() + 4000;
            const el = document.getElementById('w' + sections[i].first);
            if (el) window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY
                                       - window.innerHeight * 0.30);
          } else if (e.target.classList.contains('close')) {
            list.classList.remove('show');
          }
        };

        // ---- restore preferences, keep the screen awake ----
        const savedSize = localStorage.getItem('size');
        if (savedSize) document.documentElement.style.setProperty('--size', savedSize + 'px');
        if (localStorage.getItem('dark') === '1') document.body.classList.add('dark');

        async function keepAwake() {
          try { await navigator.wakeLock.request('screen'); } catch (e) {}
        }
        keepAwake();
        document.addEventListener('visibilitychange', () => {
          if (document.visibilityState === 'visible') keepAwake();
        });

        load();
        connect();
        </script>
        </body>
        </html>
        """#
    }
}
