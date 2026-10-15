// Only trusted libraries are evaluated. Draft content is passed as structured data.
import {chromium} from 'playwright';
import {readFile, writeFile} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
const root = dirname(fileURLToPath(import.meta.url));
const dir = process.argv[2];
const tasks = JSON.parse(await readFile(join(dir, 'tasks.json'), 'utf8'));
const local = new Map();
const origin = 'https://draw-render.invalid';
const serifFaces = [
  ['Regular', 400, 'normal'], ['Bold', 700, 'normal'],
  ['Italic', 400, 'italic'], ['BoldItalic', 700, 'italic'],
];
const serifCSS = serifFaces.map(([face, weight, style]) =>
  `@font-face{font-family:DrawSerif;src:url('${origin}/LiberationSerif-${face}.ttf');font-weight:${weight};font-style:${style};font-display:block}`
).join('');
local.set(`${origin}/`, ['text/html', Buffer.from(`<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src https://draw-render.invalid; img-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'">
<style>${serifCSS}
html,body{margin:0;background:transparent}#content{display:inline-block;vertical-align:top;font-family:DrawSerif,serif}svg{display:block}</style><div id="content"></div>`)]);
for (const [face] of serifFaces) {
  const name = `LiberationSerif-${face}.ttf`;
  local.set(`${origin}/${name}`, ['font/ttf', await readFile(join(root, 'fonts', name))]);
}
// CSS font URLs are rewritten to our exact in-memory allowlist, never a local server.
const css = (await readFile(join(root, 'bundle/katex.css'), 'utf8')).replace(/url\(([^)]+)\)/g, (match, raw) => {
  const name = raw.replace(/["']/g, '').split('/').pop();
  return `url('${origin}/katex/${name}')`;
});
for (const match of css.matchAll(/\/katex\/([^']+)/g)) {
  const name = match[1];
  local.set(`${origin}/katex/${name}`, ['font/woff2', await readFile(join(root, 'bundle/fonts', name))]);
}
let browser;
let closing = false;
async function close() {
  if (closing) return;
  closing = true;
  if (browser) await browser.close().catch(() => {});
}
process.on('SIGTERM', async () => {await close(); process.exit(1);});
process.on('SIGINT', async () => {await close(); process.exit(1);});
const watchdog = setTimeout(async () => {await close(); process.exit(1);}, 28000);
try {
  browser = await chromium.launch({headless:true, timeout:10000, args:[
    '--disable-background-networking', '--disable-component-update', '--disable-sync',
    '--no-pings', '--renderer-process-limit=1', '--js-flags=--max-old-space-size=256',
    '--force-color-profile=srgb', '--host-resolver-rules=MAP * ~NOTFOUND',
  ]});
  const context = await browser.newContext({deviceScaleFactor:2, serviceWorkers:'block', viewport:{width:1024,height:1024}});
  let rejected = false;
  await context.route('**/*', route => {
    const resource = local.get(route.request().url());
    if (!resource || route.request().method() !== 'GET') {
      rejected = true;
      return route.abort('blockedbyclient');
    }
    return route.fulfill({status:200, contentType:resource[0], body:resource[1]});
  });
  await context.routeWebSocket('**/*', ws => {rejected = true; ws.close();});
  const page = await context.newPage();
  page.setDefaultTimeout(8000);
  await page.goto(`${origin}/`);
  // Match declared font size without replacing KaTeX's math glyph fonts or script scaling.
  await page.addStyleTag({content:`${css}
    .katex{font-size:1em}
    .katex .text,.katex .text .mord{font-family:DrawSerif,serif}
  `});
  await page.addScriptTag({content:await readFile(join(root,'bundle/libraries.js'),'utf8')});
  await page.evaluate(async () => {
    await Promise.all(['', 'bold ', 'italic ', 'bold italic '].map(style =>
      document.fonts.load(`${style}14px DrawSerif`)));
  });
  for (let i=0; i<tasks.length; i++) {
    const task = tasks[i];
    const dimensions = await page.evaluate(async task => {
      const el = document.getElementById('content');
      el.replaceChildren();
      el.removeAttribute('style');
      el.style.fontSize = `${task.style.fontSize}px`;
      el.style.lineHeight = '1.35';
      el.style.color = task.style.color;
      if (task.kind === 'text') {
        el.style.width = `${task.frame.width}px`;
        el.style.whiteSpace = 'pre-wrap';
        el.style.overflowWrap = 'anywhere';
        el.textContent = task.source;
      } else if (task.kind === 'latex') {
        window.drawLibraries.katex.render(task.source, el, {
          displayMode:true, throwOnError:true, trust:false, strict:'error',
          maxExpand:1000, maxSize:100, output:'htmlAndMathml',
        });
        el.style.width = 'max-content';
        const display = el.querySelector('.katex-display');
        display.style.margin = '0';
        display.style.textAlign = 'left';
      } else if (task.kind === 'mermaid') {
        const mermaid = window.drawLibraries.mermaid;
        mermaid.initialize({startOnLoad:false, securityLevel:'strict', suppressErrorRendering:true,
          maxTextSize:65536, maxEdges:256, deterministicIds:true, deterministicIDSeed:task.id,
          theme:'base', fontFamily:'DrawSerif', htmlLabels:false,
          themeVariables:{fontFamily:'DrawSerif', fontSize:`${task.style.fontSize}px`,
            primaryColor:'#ffffff', primaryTextColor:task.style.color, primaryBorderColor:task.style.color,
            lineColor:task.style.color, secondaryColor:'#ffffff', tertiaryColor:'#ffffff',
            background:'transparent', mainBkg:'#ffffff', textColor:task.style.color,
            nodeBorder:task.style.color, clusterBkg:'#ffffff', clusterBorder:task.style.color},
          flowchart:{htmlLabels:false, useMaxWidth:false, nodeSpacing:20, rankSpacing:25},
          sequence:{useMaxWidth:false}, gantt:{useMaxWidth:false},
        });
        const {svg} = await mermaid.render(`draw_${task.id.replaceAll('-','')}`, task.source);
        const parsed = new DOMParser().parseFromString(svg, 'image/svg+xml');
        const tree = parsed.documentElement;
        if (tree.localName !== 'svg' || parsed.querySelector('parsererror')) throw Error('invalid SVG');
        if (tree.querySelector('script,foreignObject,image,a,iframe,object,embed')) throw Error('active SVG');
        for (const node of [tree, ...tree.querySelectorAll('*')]) {
          for (const attr of node.attributes) {
            if (/^on/i.test(attr.name)) throw Error('active SVG attribute');
            if (/(?:href|src)$/i.test(attr.name) && !attr.value.startsWith('#')) throw Error('SVG resource');
            for (const m of attr.value.matchAll(/url\s*\(([^)]+)\)/gi)) {
              if (!/^['"]?#[\w-]+['"]?$/.test(m[1].trim())) throw Error('SVG resource');
            }
          }
          if (node.localName === 'style' && /@import|https?:|file:|data:|url\s*\(\s*[^#]/i.test(node.textContent)) throw Error('SVG CSS resource');
        }
        // Mermaid 12 adds shape shadows by default; keep page notes undecorated.
        for (const node of tree.querySelectorAll('*')) {
          node.removeAttribute('filter');
          if (node.style) node.style.setProperty('filter','none','important');
        }
        el.append(document.importNode(tree, true));
        // Mermaid's intrinsic SVG viewBox sets geometry; do not shrink text to a max box.
        const box = tree.viewBox.baseVal;
        if (!Number.isFinite(box.width) || box.width <= 0) throw Error('invalid SVG bounds');
        el.firstChild.setAttribute('width', String(box.width));
        el.firstChild.setAttribute('height', String(box.height));
        el.firstChild.style.maxWidth = 'none';
      } else {
        const ns = 'http://www.w3.org/2000/svg';
        const svg = document.createElementNS(ns,'svg');
        svg.setAttribute('width',task.frame.width);
        svg.setAttribute('height',task.frame.height);
        svg.setAttribute('viewBox',`0 0 ${task.frame.width} ${task.frame.height}`);
        const shape = document.createElementNS(ns, task.kind === 'highlight' ? 'rect' : task.kind === 'circle' ? 'ellipse' : 'path');
        shape.setAttribute('fill','none');
        shape.setAttribute('stroke',task.style.color);
        shape.setAttribute('stroke-width',task.style.lineWidth);
        shape.setAttribute('stroke-linecap','round');
        shape.setAttribute('stroke-linejoin','round');
        if (task.kind === 'highlight') {
          shape.setAttribute('width',task.frame.width);
          shape.setAttribute('height',task.frame.height);
          shape.setAttribute('fill',task.style.color);
          shape.setAttribute('fill-opacity',task.geometry.opacity);
          shape.setAttribute('stroke','none');
        } else if (task.kind === 'circle') {
          for (const key of ['cx','cy','rx','ry']) shape.setAttribute(key,task.geometry[key]);
        } else {
          const {from:[x,y],to:[tx,ty]} = task.geometry;
          const angle = Math.atan2(ty-y,tx-x);
          const size = Math.max(5,task.style.lineWidth*4);
          shape.setAttribute('d',`M ${x} ${y} L ${tx} ${ty} M ${tx-size*Math.cos(angle-.45)} ${ty-size*Math.sin(angle-.45)} L ${tx} ${ty} L ${tx-size*Math.cos(angle+.45)} ${ty-size*Math.sin(angle+.45)}`);
        }
        svg.append(shape); el.append(svg);
      }
      await document.fonts.ready;
      if (task.kind === 'highlight') return {width:task.frame.width,height:task.frame.height};
      const box = el.getBoundingClientRect();
      const width = Math.ceil(Math.max(box.width,el.scrollWidth)*2)/2;
      const height = Math.ceil(Math.max(box.height,el.scrollHeight)*2)/2;
      if (!(width > 0 && height > 0) || width > task.frame.width || height > task.frame.height) throw Error('object exceeds placement box');
      return {width,height};
    }, task);
    if (rejected) throw Error('blocked resource');
    // Chromium truncates fractional CSS clips; alpha cropping keeps the 2x rect extent.
    const clip = task.kind === 'highlight'
      ? {width:Math.ceil(dimensions.width),height:Math.ceil(dimensions.height)} : dimensions;
    await page.screenshot({path:join(dir, `${i}.png`), omitBackground:true,
      clip:{x:0,y:0,...clip}});
  }
  await writeFile(join(dir,'done.json'), JSON.stringify({ok:true}));
} catch {
  // Do not leak private source strings through error messages or stderr.
  await writeFile(join(dir,'done.json'), JSON.stringify({ok:false}));
  process.exitCode = 1;
} finally {
  clearTimeout(watchdog);
  await close();
}
